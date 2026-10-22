// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 字形の面 1 枚。**死ぬときに面を常駐から退かせる** ([#738])。**焼いた画素を控えとして持ち、描き切りが
/// GPU のコピーで面へ届ける** ([#1792])。
///
/// ## なぜ置き場 (``GlyphAtlas``) と分けるか
///
/// 面の持ち主が置き場のままだと、広げたときに前の面を退かせる時機を置き場が決める
/// ことになる。置き場は広げた後も同じ 1 つとして生き続けるので、「前の面を読む者が
/// まだ居るか」を知らない。面ごとに持ち主を分ければ、読む側 (束・保持した形) が頁を
/// 抱え (``HeldTexture``)、全員が手放した時点で頁が死ぬ — 退かせる時機を誰も判断
/// しなくてよい ([#1079]・[#1178])。
///
/// ## なぜ控えの持ち主も頁なのか
///
/// 広げる (`grow`)・焼き直す (`rebake`) と置き場が見る頁は替わるが、**前の頁を指す列はまだそれを読む**。
/// その列が読む字は、頁が替わる前に焼かれたものである。控えを置き場が持つと、頁が替わった時点で
/// 前の頁に届けていない字を取り落とす。頁ごとに持てば、読む者が居る限り頁が生きて、控えも届く。
///
/// ## 書き込み (#1792)
///
/// 焼く口 (``GlyphAtlas``) は GPU を待たない。焼いた画素を「区画 + 画素」として積み (``stage(x:y:width:height:pixels:)``)、
/// 登録簿 (``PendingUploads``) に載せるだけである。**届けるのは描き切りの GPU 側のコピー**で、コピーは
/// 投入の順に走るので、前に投入した仕事は古い面を、このコマンドとその後の仕事は新しい面を読む。
/// 焼く区画は作りたての (まだ誰も読まない) 場所なので、前の仕事が読む画素を書き換えることも無い。
///
/// **届けた控えは、投入の結末が届くまで持つ。** GPU が投入を打ち切ったら、控えへ戻して次の描き切りが
/// 届け直す (画像と同じ・[#2199])。結末が正常なら手放す。
///
/// [#738]: https://github.com/mokume-metal/mokume/issues/738
/// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
/// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
/// [#1792]: https://github.com/mokume-metal/mokume/issues/1792
/// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor final class GlyphPage {
    let texture: any MTLTexture
    private let gpu: RenderDevice

    /// 焼いた画素 1 区画。面の `(x, y)` から `width`×`height`。
    private struct Region {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var pixels: [SIMD4<Float16>]
        /// 積んだ順の番号。``PendingUpload/markUploaded(through:by:)`` が、どこまで届けたかを見る。
        var generation: UInt64

        var byteCount: Int { pixels.count * GlyphAtlas.bytesPerPixel }
    }

    /// まだ届けていない区画。
    private var pending: [Region] = []
    /// 投入に載せて届けた区画。**その投入の結末が届くまで持つ** (打ち切られたら控えへ戻す)。
    private var delivered: [(submission: UInt64, regions: [Region])] = []
    private var lastGeneration: UInt64 = 0
    var isQueuedForUpload = false

    /// 診断: 逃げ道で待って直接書いた区画の数。**検査が読む** — 通常の焼き込みは 0 のまま。
    private(set) var directWrites = 0

    init(side: Int, gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        self.texture = try GlyphAtlas.makeTexture(side: side, gpu: gpu)
    }

    isolated deinit { gpu.retire(texture) }

    /// 焼いた画素を、描き切りが届ける控えへ積む。**待たない。**
    func stage(x: Int, y: Int, width: Int, height: Int, pixels: [SIMD4<Float16>]) {
        lastGeneration += 1
        pending.append(
            Region(
                x: x, y: y, width: width, height: height, pixels: pixels,
                generation: lastGeneration))
        gpu.pendingUploads.enqueue(self)
    }

    /// まだ届けていない区画の数。**検査が読む。**
    var pendingRegionCount: Int { pending.count }

    /// 投入に載せて届け、結末を待っている区画の数。**検査が読む。**
    var deliveredRegionCount: Int { delivered.reduce(0) { $0 + $1.regions.count } }
}

extension GlyphPage: PendingUpload {
    var pendingUploadByteCount: Int { pending.reduce(0) { $0 + $1.byteCount } }

    func stageUpload(
        into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer, at offset: Int,
        on encoder: any MTL4ComputeCommandEncoder
    ) -> UInt64 {
        var cursor = 0
        var through: UInt64 = 0
        for region in pending {
            // 区画の画素は 8 バイト単位で、区画の頭は 8 の倍数に並ぶ (幅 × 8 バイトの和)
            region.pixels.withUnsafeBytes { source in
                bytes.advanced(by: cursor).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
            encoder.copy(
                sourceBuffer: staging, sourceOffset: offset + cursor,
                sourceBytesPerRow: region.width * GlyphAtlas.bytesPerPixel, sourceBytesPerImage: 0,
                sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: region.x, y: region.y, z: 0))
            cursor += region.byteCount
            through = region.generation
        }
        return through
    }

    func uploadDirectly() -> UInt64? {
        // **控えに載せられないほど大きい字形の逃げ道だけが待つ** (画像と同じ)。焼く口は待たない。
        // 待てなければ書かず、控えに残す (#934)
        guard
            gpu.settleBeforeWriting(
                orWarn: "Could not wait for the GPU before sending glyphs to a surface, so the "
                    + "write was held back")
        else { return nil }
        for region in pending {
            region.pixels.withUnsafeBytes { source in
                texture.replace(
                    region: MTLRegionMake2D(region.x, region.y, region.width, region.height),
                    mipmapLevel: 0, withBytes: source.baseAddress!,
                    bytesPerRow: region.width * GlyphAtlas.bytesPerPixel)
            }
            directWrites += 1
        }
        return pending.last?.generation
    }

    @discardableResult
    func markUploaded(through generation: UInt64, by submission: UInt64?) -> Bool {
        let reached = pending.filter { $0.generation <= generation }
        pending.removeAll { $0.generation <= generation }
        guard !reached.isEmpty else { return false }
        // 直接書いた分は届いている。投入に載っていないので、結末を待たない
        guard let submission else { return false }
        delivered.append((submission, reached))
        return true
    }

    /// 届けた投入の結末が届いた。**打ち切られていたら、その投入が運んだ区画を控えへ戻す** ([#2199])。
    /// 次の描き切りがもう一度届ける。正常に終わっていれば手放す。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func submissionSettled(_ submission: UInt64, dropped: Bool) {
        var returned: [Region] = []
        delivered.removeAll { entry in
            guard entry.submission == submission else { return false }
            if dropped { returned += entry.regions }
            return true
        }
        guard !returned.isEmpty else { return }
        // 積んだ順を保つ — 届け直しの後で、後に積んだ区画が先に届いてもよいが、順は崩さない
        pending = (returned + pending).sorted { $0.generation < $1.generation }
        gpu.pendingUploads.enqueue(self)
    }
}
