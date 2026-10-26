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
/// 登録簿 (``PendingUploads``) に載せるだけである。**届けるのは描き切りの GPU 側のコピー**で、コピーの前に
/// 前の仕事が読み終わるのを待つ仕掛けを積む (`Canvas.encodeUploads`・[#341])。焼く区画は作りたての
/// (まだ誰も読まない) 場所なので、普段は前の仕事が読む画素を書き換えない。**届け直す区画は作りたてでは
/// ない** — 打ち切りの後も前の仕事は同じ区画を読み続けるので、書き直しはその待ちに守られる。
///
/// **届けた控えは、投入の結末が届くまで持つ。** GPU が投入を打ち切ったら、控えへ戻して次の描き切りが
/// 届け直す (画像と同じ・[#2199])。結末を失った投入と、上限を越えて忘れた打ち切りに掛かりうる投入も、
/// 字形の頁だけは届け直す側に倒す (``submissionSettled(_:dropped:)``)。
///
/// **積む量には上限がある** (``pendingByteLimit``・``pendingRegionLimit``)。1 回の描き切りが届ける量が
/// そのまま Canvas の控えの置き場の要求量になり、置き場は縮まない。越えたら、その場で待って直接書く
/// (数の並びの汚れ区間 `dirtyRangeLimit` と同じ形)。多くの字を初めて焼くフレーム (CJK の段落) だけが
/// 払う、数えられる回数の待ちである。字 1 つに GPU のコピーが 1 本なので、区画の数にも上限を置く。
///
/// [#341]: https://github.com/mokume-metal/mokume/issues/341
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
    /// ``pending`` の画素のバイト数の合計。**積む・届ける・届け直すたびに足し引きして持つ** —
    /// `stage` が 1 区画積むたびに全区画を足し直すと、多くの字を初めて焼くフレーム (区画の上限まで)
    /// で O(n^2) になる。控えを動かす口は、この 3 つ (`stage`・`markUploaded`・`submissionSettled`) だけである。
    private var pendingBytes = 0
    /// 投入に載せて届けた区画。**その投入の結末が届くまで持つ** (打ち切られたら控えへ戻す)。
    private var delivered: [(submission: UInt64, regions: [Region])] = []
    private var lastGeneration: UInt64 = 0
    var isQueuedForUpload = false

    /// 診断: 逃げ道で待って直接書いた区画の数。**検査が読む** — 通常の焼き込みは 0 のまま。
    private(set) var directWrites = 0

    /// 控えに積んでよいバイト数の上限。**超えたら、その場で待って直接書く。** 1 回の描き切りが届ける量が
    /// そのまま控えの置き場 (``Canvas`` の `uploadStorage`) の要求量になり、置き場は縮まない。上限が無いと、
    /// 最初のフレームで大きな字を大量に焼いただけで、置き場がスロットの数ぶん太ったまま残る。検査が
    /// 差し替える。
    var pendingByteLimit = GlyphPage.defaultPendingByteLimit

    /// 控えに積んでよい区画の数の上限。字 1 つに GPU のコピーが 1 本なので、数百〜数千本の
    /// コピーを 1 つのコマンドへ積まない。**超えたら、その場で待って直接書く。** 検査が差し替える。
    var pendingRegionLimit = GlyphPage.defaultPendingRegionLimit

    static let defaultPendingByteLimit = 4 << 20
    static let defaultPendingRegionLimit = 256

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
        pendingBytes += pixels.count * GlyphAtlas.bytesPerPixel
        gpu.pendingUploads.enqueue(self)
        // 積みすぎた分だけは、ここで待って届ける。待てなければ控えに残す (#934)
        if pending.count > pendingRegionLimit || pendingUploadByteCount > pendingByteLimit,
            let uploaded = uploadDirectly()
        {
            markUploaded(through: uploaded, by: nil)
        }
    }

    /// まだ届けていない区画の数。**検査が読む。**
    var pendingRegionCount: Int { pending.count }

    /// まだ届けていない区画の世代(積んだ順の番号)の並び。**検査が読む。**
    var pendingGenerations: [UInt64] { pending.map(\.generation) }

    /// 投入に載せて届け、結末を待っている区画の数。**検査が読む。**
    var deliveredRegionCount: Int { delivered.reduce(0) { $0 + $1.regions.count } }
}

extension GlyphPage: PendingUpload {
    var pendingUploadByteCount: Int { pendingBytes }

    /// 控えを区画から数え直したバイト数。**検査が読む** — 持ち回す ``pendingBytes`` とずれないことを見る。
    var recountedPendingBytes: Int { pending.reduce(0) { $0 + $1.byteCount } }

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
        // **1 回の走査**で、届けた区画を取り出し、残りを先頭へ詰める。直接書いた分 (`submission == nil`) は
        // 投入に載らず、届けた区画の配列を作らない。届けた区画の配列は、最初の 1 区画が届くと分かった
        // ところで、残りの区画数を上限に 1 回だけ確保する (何も届かない呼び出しでは確保しない)
        guard !pending.isEmpty else { return false }
        var reached: [Region] = []
        var kept = 0
        var anyReached = false
        for index in pending.indices {
            if pending[index].generation <= generation {
                if !anyReached, submission != nil { reached.reserveCapacity(pending.count - index) }
                anyReached = true
                pendingBytes -= pending[index].byteCount
                if submission != nil { reached.append(pending[index]) }
            } else {
                if kept != index { pending[kept] = pending[index] }
                kept += 1
            }
        }
        guard anyReached else { return false }
        pending.removeLast(pending.count - kept)
        // 直接書いた分は届いている。投入に載っていないので、結末を待たない
        guard let submission else { return false }
        delivered.append((submission, reached))
        return true
    }

    /// 届けた投入の結末が届いた。**打ち切られていたら (結末を失った投入を含む)、その投入が運んだ区画を
    /// 控えへ戻す** ([#2199])。次の描き切りがもう一度届ける。正常に終わっていれば手放す。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func submissionSettled(_ submission: UInt64, dropped: Bool) {
        // **結末を失った投入と、忘れた打ち切りに掛かりうる投入も、届け直す側に倒す。** 画像と数の並びは
        // 取り消さない — 正しく済んだ中身を CPU の古い値で潰しうるから。字形の区画は CPU の画素が
        // 変わらない正本で、同じ区画へ同じ画素を書き直すだけなので、倒し違えても害が無い。倒さないと、
        // 区画が空のまま頁が替わるまで字が欠け続ける (以前は CPU が直接書いたので消えなかった)
        let redeliver = dropped || gpu.undelivered(submission) == true
        var returned: [Region] = []
        delivered.removeAll { entry in
            guard entry.submission == submission else { return false }
            if redeliver { returned += entry.regions }
            return true
        }
        guard !returned.isEmpty else { return }
        pendingBytes += returned.reduce(0) { $0 + $1.byteCount }
        // 積んだ順を保つ — 届け直しの後で、後に積んだ区画が先に届いてもよいが、順は崩さない
        pending = (returned + pending).sorted { $0.generation < $1.generation }
        gpu.pendingUploads.enqueue(self)
    }
}
