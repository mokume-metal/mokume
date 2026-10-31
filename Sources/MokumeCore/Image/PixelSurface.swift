// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreVideo
import IOSurface
import Synchronization

/// 外から届いた 1 枚を、**CPU で画素を作り直さずに**絵へ書くための値。``Image/write(_:)-(PixelSurface)`` が受ける。
///
/// 動画とカメラのコマは、OS が GPU と共有する面 (`IOSurface`) に載って届く。``DisplayImage`` を作るには、
/// その全画素を CPU で Display P3 の 8 bit へ変換して並べ直す必要がある (4K で 1 枚数 ms)。この値は面を
/// そのまま持ち、色の変換は ``ColorTable`` を GPU で引いて行う
/// ([#2962](https://github.com/mokume-metal/mokume/issues/2962))。結果は、同じ表で CPU が作った
/// ``DisplayImage`` を書いたときと 1 bit も違わない。
///
/// ## 受ける面
///
/// **32 bit の BGRA (`kCVPixelFormatType_32BGRA`)・平面を持たない面だけを受け、他は `nil` を返す。**
/// 色は ``ColorTable`` が決め、不透明度は持たない (いつも不透明として書く)。透けた画素を持つ面・
/// YpCbCr の面は、今までどおり ``DisplayImage`` にして ``Image/write(_:)-(DisplayImage)`` で書く。
///
/// ## 面の寿命
///
/// **値を作った時点で、面を「使用中」にする** (`IOSurfaceIncrementUseCount`)。値の写しが全部消えると
/// 「使用中」を外す。`CVPixelBuffer` の置き場 (プール) は、使用中の面を使い回さない — だから元の
/// `CVPixelBuffer` を先に手放しても、この値を持っている間は中身が書き換わらない。絵に書いた面は、
/// 絵が次の 1 枚に書き換わるか、絵が捨てられるまで絵が持つ (GPU が読み終わるまでは描画の側も持つ)。
///
/// 外のパッケージ (別のアプリから面を受け取る道など) も、同じ口で書ける:
///
/// <!-- example: 組めない 面と表は外から受け取るもので、例の中で用意できない -->
/// ```swift
/// // surface は受け取った IOSurface、table は送り元の色から作った表
/// if let frame = PixelSurface(surface, conversion: table) {
///     picture.write(frame)
/// }
/// ```
public nonisolated struct PixelSurface: Sendable {
    /// 面と、使用中の印。
    let lease: SurfaceLease
    /// 面の 8 bit の色を、Display P3 の 8 bit の色へ写す表。
    public let conversion: ColorTable
    /// 横の画素数。
    public var width: Int { lease.surface.width }
    /// 縦の画素数。
    public var height: Int { lease.surface.height }

    /// 面と表から作る。BGRA でない面・平面を持つ面なら `nil`。
    ///
    /// - Parameters:
    ///   - surface: 32 bit の BGRA の面。作った時点で「使用中」になる。
    ///   - conversion: 面の色の意味 (色空間・伝達関数) に合わせて作った表。
    public init?(_ surface: IOSurface, conversion: ColorTable) {
        guard surface.pixelFormat == kCVPixelFormatType_32BGRA, surface.planeCount == 0,
            surface.bytesPerElement == 4, surface.width > 0, surface.height > 0
        else { return nil }
        lease = SurfaceLease(surface)
        self.conversion = conversion
    }

    /// 表を CPU で引いて、``DisplayImage`` にする。**明示的な写し** — 小さい絵へ書くときと、絵の画素を
    /// CPU で読むとき (``Image/get(_:_:)`` ほか) にだけ通る。GPU で引いた結果と bit が同じ。
    func converted() -> DisplayImage {
        let surface = lease.surface
        let (width, height, rowBytes) = (surface.width, surface.height, surface.bytesPerRow)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes)
                for x in 0..<width {
                    // BGRA の並び
                    let pixel = row.advanced(by: x * 4)
                    let (r, g, b) = conversion.convert(red: pixel[2], green: pixel[1], blue: pixel[0])
                    let index = (y * width + x) * 4
                    out[index] = r
                    out[index + 1] = g
                    out[index + 2] = b
                }
            }
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    /// 8 bit の RGB → Display P3 の 8 bit の RGB の写像を、全 16,777,216 色ぶん小さく詰めた表。
    ///
    /// **色の意味は作り手が決める。** 表は「どの 8 bit の色が、Display P3 のどの 8 bit の色になるか」だけを
    /// 持ち、色空間や伝達関数を知らない。作り手は、面と同じ色の意味を持つ 256×256 の絵を青の値ごとに
    /// 256 枚、自分の変換に通して渡す (mokume のカメラと動画は、``DisplayImage`` を作るのと同じ変換を
    /// 通す)。だから表で引いた色は、作り手が ``DisplayImage`` を作ったときの色と同じになる。
    ///
    /// ## 詰め方
    ///
    /// 写像そのものは 64 MiB だが、色を変換する写像の 2 つの性質を使って 2.625 MiB に詰める
    /// ([#2802](https://github.com/mokume-metal/mokume/issues/2802) の試作で、4 つの色条件のどれも満たした):
    ///
    /// 1. 出力の赤と緑は、入力の青に依らない
    /// 2. 入力の赤を 1 段上げたとき、出力の青は変わらないか 1 段上がる
    ///
    /// **満たさない写像からは作れず、作る口が `nil` を返す。** そのときは ``DisplayImage`` の道を使う。
    /// 表を作るのは全色を数えるので数十 ms かかる。毎フレームではなく、色の意味が決まったとき (動画を
    /// 開いたときなど) に 1 度作り、使い回す。
    public nonisolated final class ColorTable: Sendable {
        /// 出力の赤と緑。入力の `[g][r]` ごとに 2 バイト。
        let redGreen: [UInt8]
        /// 入力の `[b][g]` と赤の 32 色の区画ごとの、出力の青の頭。
        let blueBase: [UInt8]
        /// 区画の中で、赤を 1 段上げると青が上がる位置の印 (区画の 2 色目からを 0 ビット目に)。
        let blueSteps: [UInt32]

        /// 1 枚の絵 (青の値ごとの) の画素の数。
        private static let sliceCount = 256 * 256

        /// 青の値ごとの絵から作る。写像が詰め方の性質を満たさなければ `nil`。
        ///
        /// - Parameter slice: 入力の青 (0–255) を受け、その青で赤 (列) と緑 (行) を 0–255 まで並べた
        ///   256×256 の絵の変換の結果を返す。並びは RGBA の 8 bit で、`((緑 × 256) + 赤) × 4` の位置から
        ///   4 バイト。不透明度はどれも 255 でなければならない。
        public init?(converting slice: (_ blue: Int) throws -> [UInt8]) rethrows {
            var redGreen = [UInt8](repeating: 0, count: Self.sliceCount * 2)
            var blueBase = [UInt8](repeating: 0, count: Self.sliceCount * 8)
            var blueSteps = [UInt32](repeating: 0, count: Self.sliceCount * 8)
            for blue in 0..<256 {
                let image = try slice(blue)
                guard image.count == Self.sliceCount * 4 else { return nil }
                for green in 0..<256 {
                    for red in 0..<256 {
                        let pixel = (green * 256 + red) * 4
                        guard image[pixel + 3] == 255 else { return nil }
                        let pair = (green * 256 + red) * 2
                        if blue == 0 {
                            redGreen[pair] = image[pixel]
                            redGreen[pair + 1] = image[pixel + 1]
                        } else if redGreen[pair] != image[pixel] || redGreen[pair + 1] != image[pixel + 1] {
                            return nil
                        }
                        let block = (blue * 256 + green) * 8 + red / 32
                        if red % 32 == 0 {
                            blueBase[block] = image[pixel + 2]
                        } else {
                            let step = Int(image[pixel + 2]) - Int(image[pixel - 2])
                            guard step == 0 || step == 1 else { return nil }
                            blueSteps[block] |= UInt32(step) << UInt32(red % 32 - 1)
                        }
                    }
                }
            }
            self.redGreen = redGreen
            self.blueBase = blueBase
            self.blueSteps = blueSteps
        }

        /// 1 色を引く。
        public func convert(red: UInt8, green: UInt8, blue: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8) {
            let (r, g, b) = (Int(red), Int(green), Int(blue))
            let pair = (g * 256 + r) * 2
            let block = (b * 256 + g) * 8 + r / 32
            let below = blueSteps[block] & ((UInt32(1) << UInt32(r % 32)) &- 1)
            return (redGreen[pair], redGreen[pair + 1], blueBase[block] &+ UInt8(below.nonzeroBitCount))
        }

        /// GPU が読む並び (2,752,512 バイト)。赤と緑・青の頭・青の段差の印 (32 bit・リトルエンディアン) を
        /// この順に続ける。シェーダ (`imageSurfaceFragment`) が同じ位置で読む。
        var gpuBytes: [UInt8] {
            var bytes = redGreen + blueBase
            blueSteps.withUnsafeBytes { bytes.append(contentsOf: $0) }
            return bytes
        }
    }
}

/// 面を「使用中」にしておく印。値の写しが全部消えたときに外す。
nonisolated final class SurfaceLease: Sendable {
    let surface: IOSurface

    /// 生きている印の数。**検査が読む** (面を抱え続けていないかを数える)。
    static let live = Atomic<Int>(0)

    init(_ surface: IOSurface) {
        self.surface = surface
        surface.incrementUseCount()
        Self.live.add(1, ordering: .relaxed)
    }

    deinit {
        surface.decrementUseCount()
        Self.live.subtract(1, ordering: .relaxed)
    }
}
