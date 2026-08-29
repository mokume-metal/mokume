// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import VideoToolbox

/// 動きをファイルへ書き出すときに起こりうる失敗。
enum MovieWriteFailure: Error, Equatable {
    /// 書き出し先を開けない。
    case destinationUnavailable(path: String)
    /// 画素の器を借りられない。
    case bufferUnavailable
    /// 書き込みに失敗した。
    case writeFailed(path: String, reason: String)
}

/// 動画を 1 本書く。**AVFoundation に触れる唯一の場所である。**
///
/// ## 隔離の外に置く
///
/// 静止画の ``PNGFile`` と同じ姿勢で、符号化はフレームの外で走らせる
/// ([ADR-0010] 決定 4)。触るのは ``MovieWriter`` が持つ 1 本の仕事だけなので、
/// この型自身は錠を持たない。
///
/// ## 形式は選べない
///
/// ProRes 4444 の .mov で固定する。**符号化の選び方が、書き出した動きが再現するか
/// どうかを決めるからである** ([ADR-0025] 決定 3)。同じ入力を 2 回書き出して測ると、
/// H.264 は画素が一致せず、HEVC は run によって外れ、ProRes 4444 はファイルの
/// バイトまで一致した。配布向けの軽い符号化は「再現を捨てて小さくする」選択なので、
/// 要る場面が出てから足す ([ADR-0008])。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
nonisolated final class MovieFile {
    /// 時刻の刻み。24 / 25 / 30 / 50 / 60 のどれで割っても整数になる値を選ぶ —
    /// 端数が出ると、フレームの時刻が刻みへ丸められるたびに少しずつずれる。
    static let timescale: CMTimeScale = 90_000

    private let path: String
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: Double
    /// 最初の 1 枚を受け取ったか。**区間の始まりは最初のフレームの時刻**で、
    /// 0 ではない — 途中から撮り始めた動画の頭に、何も無い時間を作らないため。
    private var hasStarted = false

    /// 絵の大きさ。**開いた後は変えられない**ので、受け取った絵と食い違えば断る。
    let width: Int
    let height: Int

    init(path: String, width: Int, height: Int, frameRate: Int) throws(MovieWriteFailure) {
        self.path = path
        self.width = width
        self.height = height
        self.frameDuration = 1 / Double(max(1, frameRate))

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 同じ名前が残っていると開けない。撮り直しは上書きになるのが自然である
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw .destinationUnavailable(path: path)
        }
        self.writer = writer

        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                // **色を名乗る。** 作業空間と同じ Display P3 で書き出す ([ADR-0011] 決定 1)。
                // 名乗らないと、再生する側は狭い色域だと見なして色を寄せる
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                // **乗算していないアルファをそのまま渡す** ([ADR-0011] 決定 4 の境界)。
                // 指定しないと乗算済みとして扱われ、透けた部分の色が黒へ寄る
                AVVideoCompressionPropertiesKey: [
                    kVTCompressionPropertyKey_AlphaChannelMode as String:
                        kVTAlphaChannelMode_StraightAlpha as String,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                ],
            ])
        // 実時間に追いつく必要は無い。詰まったら待たせるほうが、落とすより正しい
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw .destinationUnavailable(path: path) }
        writer.add(input)
        guard writer.startWriting() else {
            throw .writeFailed(path: path, reason: writer.error?.localizedDescription ?? "不明")
        }
    }

    /// 1 枚を書き足す。**時刻はフレーム自身のもの**で、通し番号ではない。
    ///
    /// 詰まっているあいだは待つ。ここはフレームループの外なので、待っても絵は遅くならない。
    func append(_ image: DisplayImage, at time: Double) async throws(MovieWriteFailure) {
        guard image.width == width, image.height == height else {
            throw .writeFailed(path: path, reason: "絵の大きさが撮り始めたときと違います")
        }
        let stamp = CMTime(seconds: time, preferredTimescale: Self.timescale)
        if !hasStarted {
            writer.startSession(atSourceTime: stamp)
            hasStarted = true
        }
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard let pool = adaptor.pixelBufferPool else { throw .bufferUnavailable }
        // **器は借りて返す。** フレームごとに確保すると、長く撮ったときにだけ重くなる
        // ([ADR-0023] 決定 5)
        var borrowed: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &borrowed) == kCVReturnSuccess,
            let buffer = borrowed
        else { throw .bufferUnavailable }

        fill(buffer, with: image)
        guard adaptor.append(buffer, withPresentationTime: stamp) else {
            throw .writeFailed(path: path, reason: writer.error?.localizedDescription ?? "不明")
        }
    }

    /// 書き終える。**ファイルが閉じてから返る。**
    ///
    /// - Parameter time: 最後のフレームの時刻。ここに 1 フレームぶんを足したところが
    ///   動画の終わりになる — 足さないと最後の 1 枚が長さ 0 になり、再生されない。
    func finish(lastFrameAt time: Double) async throws(MovieWriteFailure) {
        guard hasStarted else {
            // 1 枚も受け取っていない。中身の無いファイルを残さない
            writer.cancelWriting()
            throw .writeFailed(path: path, reason: "1 枚も撮れていません")
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(
                seconds: time + frameDuration, preferredTimescale: Self.timescale))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw .writeFailed(path: path, reason: writer.error?.localizedDescription ?? "不明")
        }
    }

    /// 表示できる形の絵を、符号化器が読む並び (BGRA) へ写す。
    ///
    /// **アルファは乗算しない。** 乗算すると透けた部分の色が失われ、書き出した動きと
    /// 静止画で半透明の見え方が変わる ([ADR-0023] 決定 4 の表)。
    private func fill(_ buffer: CVPixelBuffer, with image: DisplayImage) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        image.bytes.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let row = y * stride
                let line = y * width * 4
                for x in 0..<width {
                    let to = row + x * 4
                    let from = line + x * 4
                    destination[to] = source[from + 2]
                    destination[to + 1] = source[from + 1]
                    destination[to + 2] = source[from]
                    destination[to + 3] = source[from + 3]
                }
            }
        }
    }
}
