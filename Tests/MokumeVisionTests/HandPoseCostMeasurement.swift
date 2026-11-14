// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MokumeCore
@testable import MokumeVision

/// debug で組んだか。性能は release で測る。
private nonisolated let isDebugBuild: Bool = {
    #if DEBUG
        true
    #else
        false
    #endif
}()

/// 手の推論 1 回の費用を、段ごとに測る (#3587 の完了条件 2)。**検査ではなく計測で、既定では走らない。**
///
/// `MOKUME_HAND_POSE_COST` で開き、release でだけ走る。`MOKUME_HAND_PHOTO` に手の写った写真 (JPEG・PNG) の
/// パスを渡すと、その写真で測り、手が 1 つ以上見つかり、どの手も 21 の関節を持つことも確かめる。渡さなければ
/// 黒い 640×480 の絵で測る。写真はリポジトリの外に置く (コミットしない):
///
/// ```sh
/// MOKUME_HAND_POSE_COST=1 MOKUME_HAND_PHOTO=/path/to/hand.jpg \
///   make test-release TEST_RELEASE_ARGS='--filter HandPoseCostMeasurement'
/// ```
///
/// 段は (1) 絵の画素の一括の読み出し (``Image/readPixels()``・main)、(2) 乗算を外し sRGB の転送関数を掛けて
/// Vision に渡す絵にする写し (``VisionHandPoseEstimator/picture(of:)``)、(3) Vision の推論 1 回
/// (``VisionHandPoseEstimator/detect(in:)``)。用意 (最初の 1 回) は別に出す。値は
/// `PERF\t3587\t<絵>\t<指標>\t<値>\t<単位>` の行で出す。
@MainActor
@Suite(
    "手の推論 1 回の費用 (計測)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOKUME_HAND_POSE_COST"] != nil, "MOKUME_HAND_POSE_COST で開く"),
    .enabled(if: !isDebugBuild, "性能は release で測る"),
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HandPoseCostMeasurement {
    /// 段ごとに測る回数。
    static let rounds = 30

    @Test("3587 手の推論 1 回の費用 — 読み出し・写し・推論")
    func cost() async throws {
        let photo = ProcessInfo.processInfo.environment["MOKUME_HAND_PHOTO"]
        let display = try photo.map { try Self.load($0) } ?? Self.black(width: 640, height: 480)
        let scene = photo == nil ? "black-\(display.width)x\(display.height)" : "photo-\(display.width)x\(display.height)"
        let image = try Image(
            width: display.width, height: display.height,
            pixels: Array(repeating: .zero, count: display.width * display.height), gpu: try RenderDevice())
        image.write(display)

        let estimator = VisionHandPoseEstimator()
        let preparing = ContinuousClock.now
        await estimator.prepare()
        Self.report(scene, "prepare", Self.ms(ContinuousClock.now - preparing))

        var reads: [Double] = []
        var pictures: [Double] = []
        var detects: [Double] = []
        var hands: [RawHand] = []
        for round in 0..<Self.rounds {
            let started = ContinuousClock.now
            let frame = HandPoseInput(pixels: image.readPixels(), hostTime: UInt64(round + 1))
            let read = ContinuousClock.now
            let picture = try #require(VisionHandPoseEstimator.picture(of: frame))
            let converted = ContinuousClock.now
            hands = try VisionHandPoseEstimator.detect(in: picture)
            let detected = ContinuousClock.now
            reads.append(Self.ms(read - started))
            pictures.append(Self.ms(converted - read))
            detects.append(Self.ms(detected - converted))
        }
        for (name, values) in [("readPixels", reads), ("picture", pictures), ("detect", detects)] {
            let sorted = values.sorted()
            Self.report(scene, "\(name)-median", sorted[sorted.count / 2])
            Self.report(scene, "\(name)-p90", sorted[sorted.count * 9 / 10])
        }
        let totals = zip(zip(reads, pictures), detects).map { $0.0 + $0.1 + $1 }.sorted()
        Self.report(scene, "total-median", totals[totals.count / 2])
        print("PERF\t3587\t\(scene)\thands\t\(hands.count)\tcount")

        guard photo != nil else { return }
        // 利用者へ見せる形 (画素の座標) へ写す。21 に満たない手は、ここで捨てられて数に出る
        let result = HandPoseResult.converting(hands, of: HandPoseInput(width: display.width, height: display.height, hostTime: 1))
        #expect(!result.result.hands.isEmpty, "写真に手が見つからない")
        #expect(result.dropped == 0, "関節が 21 に満たない手があった")
        for hand in result.result.hands {
            let joints = hand.joints.map { "(\($0.position.x), \($0.position.y), \($0.confidence))" }
            print("HAND\t3587\t\(hand.handedness)\t\(hand.joints.count) joints\t\(joints.joined(separator: " "))")
        }
    }

    private static func report(_ scene: String, _ name: String, _ value: Double) {
        print("PERF\t3587\t\(scene)\t\(name)\t\(String(format: "%.3f", value))\tms")
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func black(width: Int, height: Int) -> DisplayImage {
        DisplayImage(
            width: width, height: height,
            bytes: Array((0..<width * height).map { _ in [UInt8(0), 0, 0, 255] }.joined()))
    }

    /// 写真を、作業空間の原色 (Display P3) の 8 bit・アルファ非乗算の絵として読む。
    private static func load(_ path: String) throws -> DisplayImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.displayP3),
            let context = CGContext(
                data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
                bytesPerRow: picture.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        guard let data = context.data else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: picture.width * picture.height * 4))
        for at in stride(from: 3, to: bytes.count, by: 4) { bytes[at] = 255 }
        return DisplayImage(width: picture.width, height: picture.height, bytes: bytes)
    }
}
