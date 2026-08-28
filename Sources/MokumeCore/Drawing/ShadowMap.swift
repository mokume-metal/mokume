// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// 光から見た奥行きを焼き付ける面。
///
/// ## なぜ焼き付けるのか
///
/// 影は「その点が光から見えるか」で決まる。見えるかどうかは、**光から見た絵を
/// 一度描いてみる**以外に知る方法がない。だから 1 フレームに 2 回描く — 光から
/// 見て 1 回 (ここへ)、視点から見て 1 回 (画面へ)。
///
/// ## フレームの組み立ては 1 通りのまま
///
/// 描くものは既に**一度記録してから描く**形になっている ([ADR-0021] 決定 2)。影は
/// その記録をもう 1 回別の行列で描くだけなので、**影を入れても組み立ては変わらない** —
/// 重なり方も、同じフレームの画素を読み戻せることも、そのままである。
///
/// ## 作り直さない
///
/// 焼き付け先は重い下ごしらえだが、**シーンの記述として毎フレーム宣言してよい**形に
/// してある (同 決定 4)。同じ細かさなら作り直さないので、毎フレーム `shadows(true)` と
/// 書いても確保は最初の 1 回だけになる。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
final class ShadowMap {
    /// 一辺の画素数。
    let detail: Int
    /// 光から見た奥行きを入れる面。
    let texture: any MTLTexture
    /// 焼き付けるときの前後判定に使う面。
    private let depthTexture: any MTLTexture

    /// 焼き付け先の画素の形式。**奥行きを数として読む**ので色の面を使う。
    static let pixelFormat: MTLPixelFormat = .r32Float

    /// 一辺の画素数の下限と上限。
    static let detailRange = 64...4096
    /// 何も指定しなかったときの細かさ。
    static let defaultDetail = 1024

    init(gpu: RenderDevice, detail: Int) throws(RenderFailure) {
        self.detail = detail

        let color = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: detail, height: detail, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let texture = try gpu.makeTexture(descriptor: color)
        texture.label = "mokume.shadow"
        self.texture = texture

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.depthFormat, width: detail, height: detail,
            mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        let depthTexture = try gpu.makeTexture(descriptor: depth)
        depthTexture.label = "mokume.shadow.depth"
        self.depthTexture = depthTexture
    }

    /// 焼き付けるパスの記述。
    ///
    /// **いちばん奥 (1) で塗り潰してから始める。** 何も焼かれなかったところは
    /// 「無限に遠い」= 何にも遮られていない、という意味になる。
    func makeRenderPass() -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        attachment.storeAction = .store

        let depth = pass.depthAttachment!
        depth.texture = depthTexture
        depth.loadAction = .clear
        depth.clearDepth = 1
        depth.storeAction = .dontCare
        return pass
    }

    /// 光から見る視点を組む。
    ///
    /// **範囲は作品が決める** ([`shadowRange(_:)`](Canvas+Shadow.swift))。固定値に
    /// すると、その値に合った縮尺の作品でしか使えない — 小さい世界では影が潰れ、
    /// 大きい世界でははみ出す。しかもその依存が API に出ていないと、利用者からは
    /// 「影が汚い」としか言えない。
    ///
    /// - Parameters:
    ///   - direction: 光が**進む**向き。
    ///   - center: 焼き付ける範囲の中心 (ふつうは見ている先)。
    ///   - range: 焼き付ける範囲の一辺 (世界の長さ)。
    static func matrix(
        direction: SIMD3<Float>, center: SIMD3<Float>, range: Float
    ) -> simd_float4x4 {
        let travel =
            length_squared(direction) > 0 ? normalize(direction) : SIMD3<Float>(0, 1, 0)
        // 光源は、範囲のぶんだけ手前へ引いた位置に置く。奥行きは前後に 1 範囲ずつ取る
        let eye = center - travel * range
        // 光の向きと平行でない上向きを選ぶ (真上から差す光で崩れないため)
        let up: SIMD3<Float> =
            abs(travel.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, -1, 0)
        let half = range / 2
        let camera = Camera(
            eye: eye, center: center, up: up,
            // 縦は画面と同じ下向きの約束 (bottom のほうが大きい数)
            projection: .orthographic(
                left: -half, right: half, bottom: half, top: -half,
                near: 0.01, far: range * 2))
        // **画面向けの補正 (半画素のずらし) は掛けない。** ここは画面ではないので、
        // 掛けると焼き付けた位置と読む位置が半画素ずれる
        return camera.projectionMatrix * camera.viewMatrix
    }
}
