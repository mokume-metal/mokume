// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

/// 描いた結果が置かれる場所。
///
/// [ADR-0012] 決定 1 のとおり、**レンダリングの成果物はテクスチャ**で、画面表示は
/// それを受け取る経路の 1 つにすぎない。だから描画先は画面より先に立ち、画面を
/// 持たない実行でも同じものが同じように描かれる。
///
/// 画素は半精度浮動小数で持つ ([ADR-0011] 決定 2)。表示できる範囲を超えた明るさと、
/// 色域の外側の値を、出力段まで捨てずに運ぶためである。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class RenderTarget: EffectSurface {
    /// 作業空間の画素の形式。
    static let pixelFormat: MTLPixelFormat = .rgba16Float

    /// 奥行きを覚えておく面の形式。
    static let depthFormat: MTLPixelFormat = .depth32Float

    /// 1 画素あたりのバイト数 (4 成分 × 半精度浮動小数 2 バイト)。
    static let bytesPerPixel = 8

    /// 明るさを画面へ写す段の設定。**画面の性質なのでフレームを越える**。
    ///
    /// ここに置くのは、効く先が「この描画先から出て行く絵すべて」だからである。
    /// 画面へ差し出す経路も書き出す経路も、行き先は違っても出どころはここ 1 つ
    /// なので、設定も 1 つで足りる。
    var brightness = Brightness.default

    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int

    /// 描く先の面。**GPU 専用 (`.private`) で、CPU からは読めない。**
    ///
    /// CPU から読める置き場の上に載せた面 (buffer-backed のリニアテクスチャ) なら写しを
    /// 取らずに読めるが、その形には GPU のロスレス圧縮も並べ替えも効かず、**画素を読まない
    /// スケッチまで、描く・効果を通す・画面へ写すたびに素の帯域を払っていた** ([#753])。
    /// 読むときは写し (``pixelMirror``) を取る。
    ///
    /// [#753]: https://github.com/mokume-metal/mokume/issues/753
    let texture: any MTLTexture

    /// 奥行きを覚えておく面。
    ///
    /// **立体を置かないスケッチでも持つ。** 使うときだけ確保する形にすると、確保の
    /// 有無で描き方が 2 通りに分かれる — 分かれた経路は片方でしか成り立たない性質を
    /// 生む ([ADR-0021] 決定 2・3)。中身はフレームごとに捨てる (フレームの合間に描き切った分だけは、
    /// 次のフレームの最初の描き切りが引き継ぐ・[#1888]) ので、保存はしない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
    let depthTexture: any MTLTexture

    let gpu: RenderDevice

    /// この面を出す先 (``Canvas/output``) に持つ描き場所。
    ///
    /// **面を読む側が、置いたことを記録し直すために引く** ([#1543])。溜めた列が持つのは面
    /// (``HeldTexture``) だけなので、ここが無いと、貼った塗りや保持した形がどの描き場所を
    /// 読んでいるかを辿れない。弱く持つ — 持ち主は描き場所のほうで、面が寿命を延ばす
    /// 筋合いが無い。書くのは ``Canvas`` の組み立ての最後だけである。
    ///
    /// [#1543]: https://github.com/mokume-metal/mokume/issues/1543
    weak var drawer: Canvas?

    /// 出す先のテクスチャを書く最下層が、書く直前に呼ぶ検算 ([#1942])。
    ///
    /// **この面を出す先に持つ描き場所 (``drawer``) を置いた側が、もう居ないこと。**
    /// ``Canvas/settlePlacersBeforeChange()`` を通った後は空になるので、関所を通さずに出す先を書く口は、
    /// ここで debug の検査が落とす (release では何もしない)。
    ///
    /// **出す先を書く口の登録簿を兼ねる。** 呼ぶのは、出す先を書く最下層の 3 系統である。描く先への
    /// パスの記述 (``makeRenderPass(clearColor:continuingDepth:keepingDepth:)``。描き切りと ``fill(with:)``)・
    /// 画素の書き戻し (``encodePixelWriteBack(into:)``)・``Canvas`` の拡大 (`encodeUpscale`・
    /// `encodeEnlargement`)。出す先を書く口を足すときは、書く前に関所を通し、最下層がここを呼ぶ
    /// ことを確かめる。関所はコマンドを開く前に通す要があり、最下層の中へ畳めないので、口ごとに
    /// 呼ぶ形が残る。その足し忘れを、ここが捕まえる。出す先を**読む**口の登録簿は対になる側で、
    /// ``catchUpWithDrawnPicture()`` が指す ([#2104])。
    ///
    /// [#1942]: https://github.com/mokume-metal/mokume/issues/1942
    /// [#2104]: https://github.com/mokume-metal/mokume/issues/2104
    func assertPlacersSettledBeforeWriting() {
        assert(
            drawer?.placers.isEmpty ?? true,
            "A door that writes a canvas output must call Canvas.settlePlacersBeforeChange() first")
    }

    /// 画素の写し。**頼まれてはじめて作り、以後は使い回す。**
    ///
    /// 出口が 1 つも無いスケッチが出力段の置き場を払わないのと同じ作法で、画素を
    /// 読まない描画先はここで 1 バイトも払わない。
    private(set) var pixelMirror: PixelMirror?

    /// CPU が写しへ書いたまま、まだテクスチャへ戻していないか。
    var hasPendingPixelWrites: Bool { pixelMirror?.hasPendingWrites ?? false }

    /// 写しを作った回数。**作り直していないこと**と、**頼まれていなければ 0 のまま**
    /// であることを検査から数えるための目印。
    private(set) var pixelMirrorsMade = 0

    /// 写しからテクスチャへ書き戻す blit を積んだ回数。``Pixels`` へ書いたフレームだけ増える。
    private(set) var pixelWriteBacksEncoded = 0

    /// 書き戻しの組み立てを失敗させる差し込み (検査用)。製品の経路では常に `nil`。
    ///
    /// 書き戻しが投げるのは口 (encoder) を開けないときだけで、検査から自然には作れない。一方で
    /// **失敗した回に書き込み待ちが残るか**は、止まっている間の書き戻し ([#1906]) が約束する
    /// ことそのものなので、本物の失敗が起きる位置 (口を開く直前) に 1 つだけ穴を空けてある
    /// (`Canvas.failureForTesting` と同じ形)。公開はしない。
    ///
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    var failPixelWriteBackForTesting: RenderFailure?

    /// テクスチャから写しへ読み戻す blit を積んだ回数。画素を読むフレームだけ増える。
    private(set) var pixelReadbacksEncoded = 0

    /// 出力段を通した絵の置き場。**頼まれてはじめて作り、以後は使い回す。**
    ///
    /// 出口が 1 つも無いスケッチはここで 1 バイトも払わない (観測が無ければ
    /// 払わないのと同じ作法)。使い回すのは [ADR-0023] 決定 5 による。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var encodedStorage: EncodedImage?
    /// 同期で読む ``encodeForDisplay(scale:)`` が出力段を通した絵の置き場 ([#1752])。
    ///
    /// **出口へ渡す ``encodedStorage`` とは別に持つ。** あちらは次のフレームの頭まで出口へ
    /// 渡すのを控えている (#927) ので、合間の同期の読み出しが同じ 1 枚へ組むと、控えの中身が
    /// 書き換わる。頼まれてはじめて作り、以後は使い回す。
    ///
    /// [#1752]: https://github.com/mokume-metal/mokume/issues/1752
    var displayStorage: EncodedImage?
    /// 出力段を通すパイプライン。同じく頼まれてはじめて作る。
    var outputPassStorage: OutputPass?

    /// 最後に出力段を投入した番号。まだ 1 度も通っていなければ 0。
    ///
    /// **次に出力段を組む前に、これを名指しで待つ** ([#927])。``OutputPass`` は明るさを
    /// GPU 可視の置き場へ CPU で書くので、前の出力段が走っている最中には書けない。
    /// 出力段は環に載っていないため、待つ範囲は「前の 1 本」で名乗る。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    var lastEncodeSubmission: UInt64 = 0

    /// 出力段を通した絵の置き場を作った回数。**作り直していないこと**を
    /// 検査から数えるための目印。
    var encodedImagesMade = 0

    /// 出力段を通った道を通った回数。
    ///
    /// **置き場を作った回数とは別に要る。** 置き場は 1 枚を使い回すので、作った回数は
    /// 何回通っても 1 のままである。「出口が 1 つも無ければ道を 1 回も通らない」
    /// ([ADR-0023] 決定 5) を検査から見るのはこちら。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    var encodePassCount = 0

    /// 指定した大きさの描画先を確保する。
    public init(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) {
        // descriptor を組む前に、寸法の関所を通す (負の寸法は descriptor へ写せない)
        try RenderDevice.checkTextureSize(width: width, height: height)
        self.gpu = gpu
        self.width = width
        self.height = height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        // 透明な黒から始める。塗り直さずに描き足す最初のフレームが読むのは、この値
        let texture = try gpu.makeClearedTexture(descriptor: descriptor)
        texture.label = "mokume.target"
        self.texture = texture

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        let depthTexture = try gpu.makeTexture(descriptor: depth)
        depthTexture.label = "mokume.target.depth"
        self.depthTexture = depthTexture
    }

    /// **色と奥行きの面を常駐から退かせる** ([#795])。
    ///
    /// 常駐の集合は入れたものを抱えるので、描画先を手放しても面は解放されない。
    /// `createGraphics` で描き場所を作っては捨てる書き方は、これで 1 回ごとに積んでいた。
    /// 置いた列がまだ面を読むなら、列が描画先ごと抱えている (`Picture.held`) ので
    /// ここは走らない ([#1079])。写しと出力段の置き場は、それぞれの持ち主が自分で退く。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    isolated deinit {
        gpu.retire(texture)
        gpu.retire(depthTexture)
    }

    // MARK: - 画素として見る

    /// 描いた結果を画素として読み書きする面。返るのは描画先の写しへの窓である。
    ///
    /// 中身が確定しているのは GPU の仕事が終わったあとだけで、描画の経路は投入しても
    /// 待たない (#727)。だから**ここで待つ** — 投入済みのものが全部終わっていれば
    /// 何もせず返る。写しが最後に映してから GPU に新しい投入があれば、ここで読み戻しを
    /// 1 本積んで待つ (描き切りが読み戻しを積んでいれば、それは起きない)。窓は生の
    /// ポインタなので、**取ったフレームの中で使い切る**。
    ///
    /// **落ちない** ([ADR-0020] 決定 5)。写しを用意できなければ大きさ 0 の窓を返す —
    /// 読むと透明、書いても何も起きない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    var pixels: Pixels {
        gpu.settleQuietly(orWarn: "Could not wait for the GPU before reading pixels")
        do {
            let mirror = try mirrorForReading()
            return Pixels(
                base: mirror.storage.contents(), width: width, height: height,
                bytesPerRow: mirror.bytesPerRow, mirror: mirror)
        } catch {
            Diagnostics.warn("Could not make a copy of the pixels: \(error.headline)")
            return .unavailable
        }
    }

    // MARK: - 写し

    /// 写し。無ければ作る。
    private func mirrorHolding() throws(RenderFailure) -> PixelMirror {
        if let pixelMirror { return pixelMirror }
        let mirror = try PixelMirror(gpu: gpu, width: width, height: height)
        pixelMirror = mirror
        pixelMirrorsMade += 1
        return mirror
    }

    /// いまの絵を映した写し。**呼ぶ前に ``RenderDevice/settle()`` が済んでいること。**
    ///
    /// CPU が書いたまま戻していない写しは CPU の側が最新なので、映し直さない。それ以外で、
    /// 最後に映した投入より新しい投入があれば、読み戻しを 1 本積んで終わるまで待つ。
    private func mirrorForReading() throws(RenderFailure) -> PixelMirror {
        let mirror = try mirrorHolding()
        if mirror.hasPendingWrites || mirror.syncedThrough == gpu.submissionCount {
            return mirror
        }
        let submission = try gpu.withCommands { commands throws(RenderFailure) in
            try encodePixelReadback(into: commands)
            return gpu.commit(commands)
        }
        markPixelsMirrored(through: submission)
        try gpu.settle()
        return mirror
    }

    /// テクスチャから写しへ読み戻す blit を積む。**描き切りの末尾に積む形。**
    ///
    /// 積んだコマンドを投入したら、その番号を ``markPixelsMirrored(through:)`` で
    /// 知らせる — 知らせないと、次に ``pixels`` を頼まれたときにもう 1 本積む。
    func encodePixelReadback(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let mirror = try mirrorHolding()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        // **描き終わるのを待つ。** この世代は encoder をまたぐ依存を自動では張らない
        // (#341)。前の書き戻し (blit) も待つ — 間に描画が無い形でも順が崩れないように
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .blit,
            visibilityOptions: .device)
        encoder.copy(
            sourceTexture: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationBuffer: mirror.storage, destinationOffset: 0,
            destinationBytesPerRow: mirror.bytesPerRow, destinationBytesPerImage: 0)
        encoder.endEncoding()
        pixelReadbacksEncoded += 1
    }

    /// 読み戻しを積んだコマンドが、番号 `submission` で投入されたことを記録する。
    func markPixelsMirrored(through submission: UInt64) {
        pixelMirror?.syncedThrough = submission
    }

    /// CPU が写しへ書いたものをテクスチャへ戻す blit を積む。**書いていなければ何も積まない。**
    ///
    /// GPU がこの描画先へ触るコマンドの**先頭**に積む (描き切り・出力段)。積んだ blit を
    /// 後続の段が待つ仕掛けもここで積む。
    ///
    /// **この描画先を描く先に持つ ``Canvas`` があるなら、それを通す**
    /// (`Canvas.encodePixelWriteBackKeepingCarry(into:)`)。効果を掛けた面では、止まっている間に
    /// 書いた画素を効果を通す前の絵へも写す要があり、ここを直に呼ぶとそれが抜ける ([#1524])。
    ///
    /// - Returns: 積んだら `true`。**積んだコマンドを投入したら ``markPixelsWrittenBack()``
    ///   で知らせる** — ここでは「戻した」ことにしない。積んだ後で組み立てが投げると
    ///   コマンドは捨てられるので、ここで下ろすと CPU の書き込みが黙って失われる ([#1183])。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func encodePixelWriteBack(into commands: any MTL4CommandBuffer) throws(RenderFailure) -> Bool {
        guard let mirror = pixelMirror, mirror.hasPendingWrites else { return false }
        if let failPixelWriteBackForTesting { throw failPixelWriteBackForTesting }
        assertPlacersSettledBeforeWriting()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.copy(
            sourceBuffer: mirror.storage, sourceOffset: 0, sourceBytesPerRow: mirror.bytesPerRow,
            sourceBytesPerImage: 0,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        // **戻し終わるのを、続く描画・効果・読み戻しが待つ。** `.device` を渡さないと
        // 実行順だけ揃って中身が見えない (#341 で実測)
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.vertex, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
        pixelWriteBacksEncoded += 1
        return true
    }

    /// 書き戻しを積んだコマンドが投入されたことを記録する。**投入の後でだけ呼ぶ。**
    ///
    /// 積んでから投入するまでの間に CPU が写しへ書く経路は無い (どちらも main actor の上で
    /// 続けて走る) ので、ここで下ろしても書き込みは取りこぼさない。
    func markPixelsWrittenBack() {
        pixelMirror?.hasPendingWrites = false
    }

    /// CPU が写しへ書いたまま戻していないものを、**戻さずに捨てる** ([#1678])。書いていなければ
    /// 何もしない。
    ///
    /// 呼ぶのは描かずに捨てたフレームの片付け (``Canvas`` の `discardFrame()`) と、全面を塗り直す
    /// ``fill(with:)`` である。**書き込み待ちを捨てる口はここ 1 つにする** — 旗だけを下ろす形を
    /// 2 つ目の口に書くと、写しの印を戻し忘れる。
    ///
    /// 捨てたフレームで捨てるのは、書いた画素が置いた図形と同じくそのフレームに属するからである
    /// ([ADR-0021] 決定 4 の追補 (2026-09-27))。捨てたフレームの図形が次のフレームで描かれない
    /// のと同じく、書いた画素も次の描き切りで面へ戻さない。
    ///
    /// **写しは捨てた値を載せたままなので、「まだ映していない」へ戻す** (``PixelMirror/syncedThrough``
    /// を 0 に)。旗を下ろすだけだと、投入が進んでいなければ次の読み出しが写しをそのまま返し、捨てた
    /// 画素が見える。描く先は作るときに 1 本投入している (塗って始める) ので、0 は投入の番号と
    /// 一致せず、次に読むときに面から映し直す。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
    func discardPixelWrites() {
        guard let mirror = pixelMirror, mirror.hasPendingWrites else { return }
        mirror.hasPendingWrites = false
        mirror.syncedThrough = 0
    }

    // MARK: - 描く

    /// この描画先へ描くパスの記述を作る。
    ///
    /// - Parameters:
    ///   - clearColor: 塗り直す色。`nil` なら前の内容の上に描き足す。
    ///   - continuingDepth: 前の描き切りが書き出した奥行きを引き継ぐか。**「同じフレームで既に
    ///     描き切ったか」ではない** ([#1888]) — フレームの最後の描き切りは奥行きを捨てるので、
    ///     フレームの合間の最初の描き切りに読める奥行きは無い。逆に、フレームの合間 (止まっている
    ///     間・`setup()`) に描き切って残した奥行きは、次のフレームの最初の描き切りが引き継ぐ。
    ///     立てるかどうかは ``Canvas`` が持つ。
    ///   - keepingDepth: このあとに奥行きを引き継いで描き切りうるか (同じフレームの続きと、
    ///     フレームの合間に描き切るとき)。奥行きを残す。
    ///
    /// [#1888]: https://github.com/mokume-metal/mokume/issues/1888
    func makeRenderPass(
        clearColor: LinearRGBA?, continuingDepth: Bool = false, keepingDepth: Bool = false
    ) -> MTL4RenderPassDescriptor {
        assertPlacersSettledBeforeWriting()
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        attachment.storeAction = .store
        if let clearColor {
            attachment.loadAction = .clear
            // **面へ移す関所を通す** (上限を越えた成分を図形の経路と同じ ±65504 で止める・#1691)
            attachment.clearColor = HalfSurface.clearColor(clearColor)
        } else {
            attachment.loadAction = .load
        }

        // 奥行きは**フレームごと**に作り直す。**いちばん奥から始める**ので、最初に
        // 置いた立体は必ず通り、あとから来た手前のものがそれを隠す。
        //
        // 「フレームごと」であって「パスごと」ではない。1 フレームを何回かに分けて
        // 描き切ることがある (画素を読む・揺らぎの設定を書き換える・置いた描き場所の描き換えのうち、
        // 置いた側が形の組み立ての途中・写しの上限に達した・写しを用意できないとき) ので、途中の
        // 区切りで消すと**描いた順で決まる絵**に戻ってしまう。
        //
        // 残すのは途中の描き切りのときだけ。フレームの最後の描き切りで残すと、
        // 分けて描き切らないスケッチまで毎フレーム書き出しを払うことになる。
        //
        // **フレームの合間 (止まっている間・`setup()`) に描き切った立体の奥行きは、次のフレームへ
        // 引き継ぐ** (ADR-0021 決定 2 の改訂 (2026-09-30)・[#1888])。合間の描き切りは「途中の
        // 描き切り」である — 置いた立体は次のフレームの絵の一部で、そのフレームで置く立体と
        // 前後を比べられなければ、描き切らせたかどうかで絵が変わってしまう
        //
        // [#1888]: https://github.com/mokume-metal/mokume/issues/1888
        let depth = pass.depthAttachment!
        depth.texture = depthTexture
        if continuingDepth {
            depth.loadAction = .load
        } else {
            depth.loadAction = .clear
            depth.clearDepth = 1
        }
        depth.storeAction = keepingDepth ? .store : .dontCare
        return pass
    }

    /// 描画先を 1 色で塗り、GPU が終わるまで待つ。
    ///
    /// **効果を掛けた面の描画先 (``Canvas/output`` など) を止まっている間に塗るときは、``Canvas``
    /// の口を通す** (`background()`)。ここで塗ると、次のフレームの入りになる効果を通す前の絵には
    /// 届かない ([#1524](https://github.com/mokume-metal/mokume/issues/1524))。
    ///
    /// **出す先を塗る前に、置いた側へ置いた時点の絵を写させる** ([#1942])。この面を出す先に持つ
    /// 描き場所が置かれていても、置いた側に塗った後の絵は出ない。
    ///
    /// [#1942]: https://github.com/mokume-metal/mokume/issues/1942
    public func fill(with color: LinearRGBA) throws(RenderFailure) {
        // 描画先の絵が変わる前に、置いた側へ写させる (`Canvas.settlePlacersBeforeChange()`)。置いた側が
        // 居なければ (`createGraphics` が作った直後など) 何もしない。コマンドを開く前に通す
        drawer?.settlePlacersBeforeChange()
        // 全画素を塗り直すので、写しに残っていた CPU の書き込みは戻さず捨てる。**旗だけ下ろさず、
        // 捨てる口を通す** ([#1678] の反証 3) — 塗る投入より前に投げると、投入の番号が進まないまま
        // 捨てた値を載せた写しが読まれる
        //
        // [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        discardPixelWrites()
        try gpu.withCommands { commands throws(RenderFailure) in
            guard
                let encoder = commands.makeRenderCommandEncoder(
                    descriptor: makeRenderPass(clearColor: color))
            else {
                throw .encoderUnavailable
            }
            encoder.endEncoding()
            try gpu.commitAndWait(commands)
        }
    }

    // MARK: - 読み出す

    /// 描画先の内容を CPU 側へ読み出す。
    ///
    /// 読み出せるのは**作業空間そのままの値**で、表示のための変換は経ていない。
    /// 表示・書き出しのための変換は出力段が 1 度だけ行う ([ADR-0011] 決定 3)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// 読むのは写し (`pixels` と同じ置き場) である。待つのは投入済みの描画が終わる
    /// まで (全部終わっていれば何もしない・#727) で、写しが古ければ読み戻しを 1 本積んで
    /// 待つ。行の間隔が幅ぶんより広いことがあるので、値としての ``PixelBuffer`` へ移す
    /// ときに詰める。
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        // 出す先なら、止まっている間に変わった描く先を広げ直してから読む ([#1882])
        //
        // [#1882]: https://github.com/mokume-metal/mokume/issues/1882
        try catchUpWithDrawnPicture()
        try gpu.settle()
        let mirror = try mirrorForReading()
        let componentsPerRow = width * 4
        var components = [Float16](repeating: 0, count: componentsPerRow * height)
        let source = mirror.storage.contents()
        components.withUnsafeMutableBytes { destination in
            let base = destination.baseAddress!
            for row in 0..<height {
                base.advanced(by: row * componentsPerRow * 2)
                    .copyMemory(
                        from: source.advanced(by: row * mirror.bytesPerRow),
                        byteCount: width * Self.bytesPerPixel)
            }
        }
        return PixelBuffer(width: width, height: height, components: components)
    }
}

/// 描画先の画素の写し。CPU から読み書きできる置き場。
///
/// **どちらが最新かを 2 つの値で持つ。** `hasPendingWrites` が立っていれば CPU の側が
/// 最新で、次に GPU がこの描画先へ触る前に書き戻される。立っていなければ GPU の側が
/// 最新で、`syncedThrough` (最後に映した投入の番号) より新しい投入があれば映し直す。
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor final class PixelMirror {
    /// 置き場。`.shared` なので CPU からそのまま読み書きできる。
    let storage: any MTLBuffer
    /// 死ぬときに置き場を退かせる先。
    private let gpu: RenderDevice
    /// 1 行あたりのバイト数。
    let bytesPerRow: Int
    /// CPU が書いたまま、まだテクスチャへ戻していないか。
    var hasPendingWrites = false
    /// この番号までの投入の結果を映している。0 は面を映していない — まだ 1 度も映していないか、
    /// 捨てた書き込みを載せている (``RenderTarget/discardPixelWrites()``)。
    var syncedThrough: UInt64 = 0

    init(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) {
        // blit の行間隔に整列の要求は無い (リニアテクスチャを置き場に載せるときの要求は
        // ここには効かない) ので、幅ぶんそのままでよい
        bytesPerRow = width * RenderTarget.bytesPerPixel
        storage = try gpu.makeReadableBuffer(byteCount: bytesPerRow * height)
        storage.label = "mokume.target.mirror"
        self.gpu = gpu
    }

    /// **置き場を常駐から退かせる** ([#795])。画素の窓 (``Pixels``) は写しを抱えるので、
    /// 窓を使い切るまではここは走らない。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit { gpu.retire(storage) }
}
