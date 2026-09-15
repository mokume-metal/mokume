// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 積んだ控えと、その世代。**投入した後で** ``PendingUploads/markUploaded(_:)`` へ渡す。
typealias EncodedUploads = [(owner: any PendingUpload, generation: UInt64)]

// 数の並びと画像へ CPU が書いた控えを、GPU 側のコピーで届ける。
//
// **書く口は待たない** ([#749])。控えを写す置き場は環 (`FrameRing`) に載った
// ``GrowableBuffer`` で、写すのは描き切りが環を進めて待った後か、読み戻しが投入済みの
// 全部を待った後に限る。届けるコピーは投入の順に走るので、前に投入した仕事は古い値を、
// このコマンドとその後の仕事は新しい値を読む — CPU が書いた順と同じである。
//
// 形は描き場所への画素の書き戻し (`RenderTarget.encodePixelWriteBack`) と同じで、写す
// → 続く段が待つ仕掛けを積む → **投入した後で**控えを下ろす ([#1183])。
//
// [#749]: https://github.com/mokume-metal/mokume/issues/749
// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
extension Canvas {
    /// 届けていない控えを、コマンドの先頭に積む。**控えが無ければ何も積まない。**
    ///
    /// 呼んでよいのは、控えの置き場のいまのスロットを読む投入が終わっているときだけで
    /// ある (描き切りなら `frameRing.advance()` の後、読み戻しなら全完了を待った後)。
    ///
    /// - Returns: 積んだ (か、逃げ道で直接書いた) 控えと世代。**投入した後で**
    ///   ``PendingUploads/markUploaded(_:)`` へ渡す。
    func encodeUploads(into commands: any MTL4CommandBuffer) throws(RenderFailure)
        -> EncodedUploads
    {
        let owners = gpu.pendingUploads.owners
        guard !owners.isEmpty else { return [] }

        var uploaded: EncodedUploads = []
        var staged: [(owner: any PendingUpload, offset: Int)] = []
        var total = 0
        for owner in owners {
            let byteCount = owner.pendingUploadByteCount
            guard byteCount <= uploadByteLimit else {
                // **大きすぎる品は、待って直接書く。** 待てなければ控えに残る (#934)。
                // 直接書いた分は投入によらず届いているが、下ろすのは他と揃えて投入の後
                if let generation = owner.uploadDirectly() {
                    uploaded.append((owner, generation))
                }
                continue
            }
            // 画素は 8 バイト単位なので、頭を 8 の倍数に揃えておく
            let offset = (total + 7) & ~7
            staged.append((owner, offset))
            total = offset + byteCount
        }
        guard !staged.isEmpty else { return uploaded }

        // **置き場は積む前に 1 度だけ取る** (``GrowableBuffer/buffer(holding:)``)
        let (staging, bytes) = try uploadStorage.writableBytes(holding: total)
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        for item in staged {
            let generation = item.owner.stageUpload(
                into: bytes.advanced(by: item.offset), of: staging, at: item.offset,
                on: encoder)
            uploaded.append((item.owner, generation))
        }
        // **届け終わるのを、続く計算・描画・書き戻しが待つ。** 同じコマンドの中の encoder を
        // またぐ依存は自動では張られない (#341)。`.device` を渡さないと実行順だけ揃って
        // 中身が見えない
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.dispatch, .vertex, .fragment, .blit],
            visibilityOptions: .device)
        uploadBarriersEncoded += 1
        encoder.endEncoding()
        return uploaded
    }
}
