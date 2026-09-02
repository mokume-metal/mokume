// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

/// 描いた絵を、表示できる面へ差し出す。
///
/// 描画とは別のパスにしてある。**描く解像度と、それを映す面の大きさを切り離す**ため
/// で、面をどうリサイズしてもスケッチは同じ解像度で描き続け、余った領域は帯になる。
/// 画面へ差し出せる 1 枚。
///
/// **差し出す経路が源に求めるものは 4 つだけ**である。走っているスケッチの描画先
/// (``RenderTarget``) も、別のプロセスが書いた共有の面 (``SharedFrameWindow``) も、
/// 同じ経路を通れる — [ADR-0012] 決定 1 の「成果物はテクスチャ」がそのまま効く。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
protocol PresentableFrame {
    var texture: any MTLTexture { get }
    var width: Int { get }
    var height: Int { get }
    /// 明るさを画面へ写す段の設定。**既に焼かれている絵は既定を名乗る** — 既定は
    /// 断片が早期に返す設定なので、二度目の経路で画素が動かない。
    var brightness: Brightness { get }
}

extension RenderTarget: PresentableFrame {}

@MainActor
final class FramePresenter {
    private let gpu: RenderDevice
    private let pipeline: PresentPipeline

    /// 面を取れずに見送ったフレームの数。
    ///
    /// 面が足りないときは待たずに見送る。**「見送った」ことを数えて外から読めるように
    /// しておく** — 絵が出ない・動きが飛ぶといった症状の出どころが、ここを見れば分かる。
    private(set) var missedFrames = 0

    /// 前回差し出した面の大きさ。まだ 1 枚も差し出していなければ `(0, 0)`。
    ///
    /// 面の環は Metal 側が持っていて、**大きさが変わると環ごと作り直される**。古い面を
    /// 常駐させたままにすると際限なく積み上がるので、変わったことをここで見て畳む
    /// ([#357](https://github.com/mokume-metal/mokume/issues/357))。
    private var lastDrawableSize = (width: 0, height: 0)

    /// 描いた絵を画面へ出すべきか。
    ///
    /// 窓が見えていない間は出さない — 誰も見ない絵のために `nextDrawable()` の待ちを
    /// 払わないためで、**描くほうは止めない** (止めるのは出すほうだけ・#223)。
    ///
    /// **最初の 1 回は無条件に通す。** 見えているかの判定は窓が出てから更新されるので、
    /// それを待たずに描き終えるスケッチ (1 枚しか描かないもの) が、永久に何も表示
    /// しないことになる。
    static func shouldPresent(windowIsVisible: Bool, hasPresented: Bool) -> Bool {
        hasPresented ? windowIsVisible : true
    }

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        self.gpu = gpu
        self.pipeline = try PresentPipeline(gpu: gpu, pixelFormat: pixelFormat)
    }

    /// 描いた絵を面へ差し出す。
    ///
    /// - Returns: 差し出したら `true`。面を取れずに見送ったら `false`。
    @discardableResult
    func present(_ source: some PresentableFrame, to layer: CAMetalLayer) throws(RenderFailure) -> Bool {
        guard let drawable = layer.nextDrawable() else {
            missedFrames += 1
            return false
        }

        // 差し出す面も**常駐の集合を通す**。通し忘れると検証レイヤが「どの residency
        // set にも入っていない」と言い、実装や OS の版が変われば黙って壊れうる ([#357])
        let size = (width: drawable.texture.width, height: drawable.texture.height)
        if size != lastDrawableSize {
            // 大きさが変わった = 前の環は死んだ。畳んでから入れ直す
            try gpu.releaseDrawableResidency()
            lastDrawableSize = size
        }
        gpu.makeDrawableResident(drawable.texture)

        gpu.waitForDrawable(drawable)
        let commands = try gpu.beginCommands()
        try encode(source, into: drawable.texture, using: commands)
        // GPU の完了を待たない — 待てば表示のたびに CPU が止まる
        gpu.commit(commands, signalling: drawable)
        drawable.present()
        return true
    }

    /// 描いた絵を、渡したテクスチャへ収める (帯を含む)。GPU の完了まで待つ。
    ///
    /// 面へ差し出すのと**同じ経路**で、行き先だけが違う。画面を持たない実行から
    /// 「画面に出るはずの絵」を取り出せるので、収まり方を機械で検められる。
    func draw(_ source: some PresentableFrame, into destination: any MTLTexture) throws(RenderFailure) {
        let commands = try gpu.beginCommands()
        try encode(source, into: destination, using: commands)
        try gpu.commitAndWait(commands)
    }

    /// 収まる矩形を決めて、1 枚のパスとして書き込む。
    private func encode(
        _ source: some PresentableFrame, into destination: any MTLTexture,
        using commands: any MTL4CommandBuffer
    ) throws(RenderFailure) {
        let descriptor = MTL4RenderPassDescriptor()
        let attachment = descriptor.colorAttachments[0]!
        attachment.texture = destination
        attachment.loadAction = .clear
        // 収まらなかった領域は帯になる。黒で塗る
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        attachment.storeAction = .store

        let fit = ViewportFit.fit(
            contentAspect: Double(source.width) / Double(source.height),
            surfaceWidth: Double(destination.width),
            surfaceHeight: Double(destination.height))

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw .encoderUnavailable
        }
        pipeline.setSource(source.texture)
        // 明るさを写す段は**画面が持つ**。行き先が窓でも面でも同じ設定が効く
        pipeline.setBrightness(source.brightness)
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setViewport(
            MTLViewport(
                originX: fit.x, originY: fit.y, width: fit.width, height: fit.height,
                znear: 0, zfar: 1))
        encoder.setArgumentTable(pipeline.argumentTable, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
