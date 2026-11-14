// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import MokumeCore
import MokumeDiagnostics
import Synchronization
import Vision

/// OS の Vision (`VNDetectHumanHandPoseRequest`) で手の関節点を取る推論。
///
/// 返す点は Vision の座標のまま (0〜1・左下が原点)。画素の座標へは ``HandPoseResult/converting(_:of:)`` が写す。
/// Vision が返さなかった関節がある手は、関節が 21 に満たない手として写しの側で捨てられる (欠けた関節を埋めない)。
///
/// **用意:** 初めて推論する回はモデルの読み込みで数秒かかる。``prepare()`` は黒い小さな絵を 1 度推論して
/// 読み込みを済ませ、何度呼んでも 1 度しか走らない。``estimate(_:)`` は用意が済むまで待ってから推論する。
///
/// Vision が推論に失敗したら (投げたら)、空を返し、最初の 1 度だけ診断へ名乗る。
nonisolated final class VisionHandPoseEstimator: HandPoseEstimator {
    /// 1 枚の絵で探す手の数の上限。
    static let maximumHandCount = 2

    private let warmUp = Mutex<Task<Void, Never>?>(nil)
    private let toldFailure = Mutex(false)
    private let tell: @Sendable (String) -> Void

    /// - Parameter tell: 名乗る先。既定は診断 (標準エラーと観測の応答の `warnings`)。
    init(tell: @escaping @Sendable (String) -> Void = { Diagnostics.warn($0) }) {
        self.tell = tell
    }

    func prepare() async {
        let task = warmUp.withLock { slot -> Task<Void, Never> in
            if let slot { return slot }
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let blank = Self.blank else { return }
                _ = detectReportingFailure(in: blank)
            }
            slot = task
            return task
        }
        await task.value
    }

    func estimate(_ frame: HandPoseInput) async -> [RawHand] {
        await prepare()
        guard !Task.isCancelled, let picture = Self.picture(of: frame) else { return [] }
        return detectReportingFailure(in: picture)
    }

    private func detectReportingFailure(in picture: CGImage) -> [RawHand] {
        do {
            return try Self.detect(in: picture)
        } catch {
            let first = toldFailure.withLock { told -> Bool in
                defer { told = true }
                return !told
            }
            if first {
                tell(
                    "hand pose: Vision could not look for hands (\(error.localizedDescription)), so the result has "
                        + "no hands. This is said once")
            }
            return []
        }
    }

    // MARK: - Vision

    /// 手の関節の名前 (``HandJointName`` の順) に当たる Vision の名前。
    static let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// 絵 1 枚から手を探す。手が写っていなければ空。
    static func detect(in picture: CGImage) throws -> [RawHand] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHandCount
        let handler = VNImageRequestHandler(cgImage: picture, orientation: .up, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map { observation in
            let points = (try? observation.recognizedPoints(.all)) ?? [:]
            // Vision が返さなかった関節は埋めない (21 に満たない手として写しの側で捨てる)
            let joints = jointNames.compactMap { name in
                points[name].map {
                    RawJoint(x: Float($0.location.x), y: Float($0.location.y), confidence: $0.confidence)
                }
            }
            return RawHand(handedness: handedness(observation.chirality), joints: joints)
        }
    }

    static func handedness(_ chirality: VNChirality) -> Handedness {
        switch chirality {
        case .left: .left
        case .right: .right
        default: .unknown
        }
    }

    // MARK: - 画素から絵へ

    /// 読み出した画素を、Vision に渡す絵にする。
    ///
    /// ``PixelBuffer`` の成分は線形・アルファ乗算済みである。Vision へは、出力段と同じ写し
    /// (``OutputStage/encode(_:)``) で**乗算を外し、sRGB の転送関数を掛けて 8 bit にした絵**を渡す。原色は
    /// 作業空間の Display P3 のままなので、絵にはその色空間を名乗らせる (Vision が色を合わせる)。
    /// 画素の並び (左上が原点・行優先) は変えないので、左右を入れ替えた絵の点は、入れ替えた後の絵の座標で返る。
    /// 画素を持たない写し・大きさが 0 の写しは `nil` を返す。
    static func picture(of frame: HandPoseInput) -> CGImage? {
        guard let pixels = frame.pixels, frame.width > 0, frame.height > 0 else { return nil }
        return cgImage(OutputStage.encode(pixels))
    }

    private static func cgImage(_ display: DisplayImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(display.bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        return CGImage(
            width: display.width, height: display.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: display.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 用意に推論する、黒い小さな絵。
    static let blank: CGImage? = cgImage(
        DisplayImage(
            width: 64, height: 64, bytes: Array((0..<64 * 64).map { _ in [UInt8(0), 0, 0, 255] }.joined())))
}
