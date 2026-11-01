// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 積んだ控えと、その世代。**投入した後で** ``RenderDevice/noteUploaded(_:by:)`` へ渡す。
///
/// `direct` は逃げ道で待って直接書いた分 (``PendingUpload/uploadDirectly()``)。投入に載らないので、
/// 投入が打ち切られても取り消さない ([#2199])。
///
/// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
typealias EncodedUploads = [(owner: any PendingUpload, generation: UInt64, direct: Bool)]

// 数の並びと画像へ CPU が書いた控えを、GPU 側のコピーで届ける。
//
// **書く口は待たない** ([#749])。控えを写す置き場は環 (`FrameRing`) に載った
// ``GrowableBuffer`` で、写すのは描き切りが環を進めて待った後か、読み戻しが投入済みの
// 全部を待った後に限る。届けるコピーは投入の順に走るので、前に投入した仕事は古い値を、
// このコマンドとその後の仕事は新しい値を読む。**ただし順を守らせるのは、コピーの前に積む待ち
// (`barrier`) である** — 積まなければ、前の仕事が読んでいる最中に上書きしうる ([#341])。
// **数の並びでは、これが CPU が呼んだ順と揃う** —
// 書く口が、書く前に頼まれてその並びに触れる計算を先に投入するからである (`Numbers.write`・
// [#1687])。画像は描き切りの時点の画素を送る約束で、呼んだ順には揃えない (#749)。
//
// 形は描き場所への画素の書き戻し (`RenderTarget.encodePixelWriteBack`) と同じで、写す
// → 続く段が待つ仕掛けを積む → **投入した後で**控えを下ろす ([#1183])。
//
// [#341]: https://github.com/mokume-metal/mokume/issues/341
// [#749]: https://github.com/mokume-metal/mokume/issues/749
// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
// [#1687]: https://github.com/mokume-metal/mokume/issues/1687
extension Canvas {
    /// 届けていない控えを、コマンドの先頭に積む。**控えが無ければ何も積まない。**
    ///
    /// 呼んでよいのは、控えの置き場のいまのスロットを読む投入が終わっているときだけで
    /// ある (描き切りなら `frameRing.advance()` の後、読み戻しなら全完了を待った後)。
    ///
    /// - Returns: 積んだ (か、逃げ道で直接書いた) 控えと世代。**投入した後で**
    ///   ``RenderDevice/noteUploaded(_:by:)`` へ渡す。
    func encodeUploads(into commands: any MTL4CommandBuffer) throws(RenderFailure)
        -> EncodedUploads
    {
        // 届けるものが無いフレームでも、止めた動画の面を手放す (#2962)
        imageInputPass?.forgetIdleSurfaces()
        guard encodesUploads else { return [] }
        let owners = gpu.pendingUploads.owners

        var uploaded: EncodedUploads = []
        var staged: [(owner: any PendingUpload, offset: Int)] = []
        var total = 0
        for owner in owners {
            let byteCount = owner.pendingUploadByteCount
            guard byteCount <= uploadByteLimit else {
                // **大きすぎる品は、待って直接書く。** 待てなければ控えに残る (#934)。
                // 直接書いた分は投入によらず届いているが、下ろすのは他と揃えて投入の後
                if let generation = owner.uploadDirectly() {
                    uploaded.append((owner, generation, direct: true))
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
        var cpuStaged: [(owner: any PendingUpload, offset: Int)] = []
        var imageIndex = 0
        for item in staged {
            if let image = item.owner as? Image, image.deferredInput != nil,
                !imageInputUnavailable, !failImageInputForTesting
            {
                do {
                    if imageInputPass == nil {
                        imageInputPass = try ImageInputPass(gpu: gpu, slotCount: frameRing.slotCount)
                    }
                    // 面の入力は、面を読む準備ができなければその 1 枚だけを CPU で届ける (表を CPU で引く)。
                    // 他の絵の GPU の変換は止めない (#2962)
                    var source: ImageInputPass.SurfaceSource?
                    if image.inputNeedsDecode, let surface = image.surfaceInput {
                        guard let prepared = imageInputPass!.surfaceSource(for: surface) else {
                            cpuStaged.append(item)
                            continue
                        }
                        source = prepared
                    }
                    let generation = try imageInputPass!.stage(
                        image, source: source, into: bytes.advanced(by: item.offset), of: staging,
                        at: item.offset, slot: frameRing.slot, index: imageIndex, in: commands)
                    imageIndex += 1
                    uploaded.append((image, generation, direct: false))
                    uploadBarriersEncoded += 1
                    continue
                } catch {
                    // 準備に失敗しても公開の失敗は増やさず、同じ値を CPU から送る。
                    // 同じ Canvas で毎フレーム失敗する準備を繰り返さない。
                    imageInputUnavailable = true
                }
            }
            cpuStaged.append(item)
        }
        guard !cpuStaged.isEmpty else { return uploaded }
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        // **コピーの前に、前の仕事が読み終わるのを待つ** ([#341]・#1792 の反証)。同じコマンドの中でも、
        // 前に投入したコマンドとも、encoder をまたぐ依存はこの世代では自動では張られない — 「コピーは
        // 投入の順に走る」だけでは、前のフレームの描きがまだ読んでいる画素・値を上書きしうる。上書きされる
        // のは、書き換えた画像・数の並びと、打ち切りの後に届け直す字形の区画である。待つのは断片・計算・
        // blit の段で、頂点段は面も控えも読まない。費用は PR #3110 の本文にある
        encoder.barrier(
            afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .blit,
            visibilityOptions: .device)
        uploadWaitsEncoded += 1
        for item in cpuStaged {
            let generation = item.owner.stageUpload(
                into: bytes.advanced(by: item.offset), of: staging, at: item.offset,
                on: encoder)
            uploaded.append((item.owner, generation, direct: false))
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
