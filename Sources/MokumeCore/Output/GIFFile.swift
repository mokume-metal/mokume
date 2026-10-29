// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import MokumeDiagnostics
import UniformTypeIdentifiers

/// 動きを GIF 1 本として書く ([#2440])。**外の道具に頼らず、ImageIO で書く。**
///
/// ## 配る形であって、元にする形ではない
///
/// GIF は 256 色・1 ビットの透け・1/100 秒刻みの遅延という、**配る相手の再生環境が広い代わりに
/// 絵を削る形**である。減色の器は OS (ImageIO) のもので、版で変わりうる。だから**同じ引数から書いても
/// 画素が一致するとは約束しない** — 元にするなら `.mov` か PNG 連番 ([ADR-0025] 決定 3)。
///
/// ## 書き方
///
/// - **色**: sRGB へ写してから書く (``DistributionColor``)。GIF には色空間の印が無い
/// - **256 色**: 1 枚ごとに ImageIO が色表を作る (枚ごとの色表)
/// - **透け**: アルファが ``DistributionColor/gifThreshold`` 以上は不透明、未満は透明。半透明は書かない。
///   透けのある枚は「前の絵を消してから次を描く」と宣言する (下に前の枚が残らない)
/// - **遅延**: 1 枚あたり `100 / fps` の 1/100 秒。**割り切れない fps は書く前に断る**
///   (``delay(frameRate:)``・黙って丸めない・枚を間引かない)
/// - **繰り返し**: 無限
///
/// ## 1 枚ずつ書き足す (メモリが伸びない)
///
/// ImageIO の複数枚の GIF の書き手は、閉じるまで全部の枚を抱える (1920×1080 の 100 枚で 1.2 GB、閉じる
/// ときに 2.6 GB まで伸びた — 測った)。長く書いたときにだけ重くなる形は作らない
/// ([ADR-0023] 決定 5)。だから **ImageIO には 1 枚ずつ、1 枚だけの GIF を作らせ** (色表と圧縮は
/// ImageIO のもの)、その中身 (色表と画素の圧縮列) を、**こちらが組む 1 本の GIF の枠 (``GIFBlocks``)** へ
/// 写して、ファイルへ書き足す。1 度に抱えるのは 1 枚ぶんである。
///
/// 隔離の外に置く ([ADR-0010] 決定 4)。触るのは ``MovieWriter`` が持つ 1 本の仕事だけなので、
/// この型自身は錠を持たない。
///
/// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
nonisolated final class GIFFile: MovieOutput {
    /// 遅延の刻み (1 秒をこの数で割る)。GIF の遅延は 1/100 秒の整数倍である。
    static let delayUnitsPerSecond = 100

    /// 1 枚の遅延 (1/100 秒) を求める。**割り切れなければ `nil`** — 丸めない。
    static func delay(frameRate: Int) -> Int? {
        guard frameRate > 0, delayUnitsPerSecond % frameRate == 0 else { return nil }
        return delayUnitsPerSecond / frameRate
    }

    /// 書ける fps (1 枚の遅延が 1/100 秒の整数倍になるもの) のうち、`frameRate` に近い上下の 1 つずつ。
    /// 断る文面が名指す。`frameRate` 以上・以下が無いほうは `nil`。
    static func nearestFrameRates(to frameRate: Int) -> (below: Int?, above: Int?) {
        let usable = (1...delayUnitsPerSecond).filter { delayUnitsPerSecond % $0 == 0 }
        return (usable.last { $0 < frameRate }, usable.first { $0 > frameRate })
    }

    /// 書き出し先 (名乗る名前)。``placement`` があれば、閉じ終えるまでここにあるものには触れない (#3426)。
    private let path: String
    /// 行き先の隣の一時ファイルへ書き、書き損じなく閉じ終えたときだけ ``path`` へ置く段取り。`nil` なら直に書く。
    private let placement: AtomicFile.Placement?
    /// バイトを書く場所 (``placement`` があれば一時ファイル)。
    private let writtenPath: String
    private let handle: FileHandle
    private let delay: Int
    private var added = 0
    private var width = 0
    private var height = 0

    /// - Parameter frameRate: 1 秒あたりの枚数。**``delay(frameRate:)`` が割り切れる値だけ**を渡す。
    /// - Parameter placement: 隣の一時ファイルへ書いて、閉じ終えたときだけ ``path`` へ置く段取り (#3426)。
    init(path: String, frameRate: Int, placement: AtomicFile.Placement? = nil) throws(MovieWriteFailure) {
        // **書き出し先がディレクトリなら、消さずに断る** (``MovieFile`` と同じ・#2859)
        if AtomicFile.isDirectory(URL(fileURLWithPath: path), following: false) {
            throw .writeFailed(path: path, reason: Diagnostics.posixReason(EISDIR))
        }
        guard let delay = Self.delay(frameRate: frameRate) else {
            throw .writeFailed(
                path: path,
                reason: "a GIF counts each frame's time in 1/100 of a second, and 1/\(frameRate) "
                    + "of a second is not a whole number of them")
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 書く場所に同じ名前が残っていると、作り直す。**消すのは書く場所だけ**で、一時ファイルを使うときは
        // 行き先の前のファイルは閉じ終えるまで残る (#3426)。使わない形では書く場所が行き先なので、撮り直しは上書きになる
        let writtenPath = placement?.temporary.path ?? path
        try? FileManager.default.removeItem(atPath: writtenPath)
        guard FileManager.default.createFile(atPath: writtenPath, contents: nil),
            let handle = FileHandle(forWritingAtPath: writtenPath)
        else { throw .destinationUnavailable(path: path) }
        self.path = path
        self.placement = placement
        self.writtenPath = writtenPath
        self.handle = handle
        self.delay = delay
    }

    deinit { try? handle.close() }

    func append(_ image: DisplayImage, at time: Double) async throws(MovieWriteFailure) {
        if added == 0 {
            width = image.width
            height = image.height
        }
        guard image.width == width, image.height == height else {
            throw .writeFailed(path: path, reason: "the frame size differs from when recording began")
        }
        let converted = DistributionColor.srgb(image, alpha: .threshold)
        // **透けた画素の無い枚は、アルファを持たない絵として渡す。** アルファのある絵として渡すと、
        // 使っていない色を「透け」に割り当てた GIF を作る (測った)。透けの印が付くと、消し方も変わる
        let hasTransparency = stride(from: 3, to: converted.bytes.count, by: 4).contains {
            converted.bytes[$0] == 0
        }
        guard let picture = Self.cgImage(of: converted, withAlpha: hasTransparency) else {
            throw .bufferUnavailable
        }
        // ImageIO に 1 枚だけの GIF を作らせ、色表と圧縮列を取り出す
        guard let single = Self.encodeSingle(picture), let blocks = GIFBlocks.parse(single) else {
            throw .writeFailed(path: path, reason: "the image encoder could not make a GIF frame")
        }
        do {
            if added == 0 {
                try handle.write(contentsOf: GIFBlocks.header(width: width, height: height))
            }
            try handle.write(contentsOf: blocks.frame(delay: delay))
        } catch {
            throw .writeFailed(path: path, reason: Diagnostics.failureText(error))
        }
        added += 1
    }

    func finish(lastFrameAt time: Double) async throws(MovieWriteFailure) {
        guard added > 0 else {
            // 1 枚も受け取っていない。中身の無いファイルを残さない
            try? handle.close()
            try? FileManager.default.removeItem(atPath: writtenPath)
            throw .writeFailed(path: path, reason: "not a single frame was recorded")
        }
        do {
            try handle.write(contentsOf: GIFBlocks.trailer)
            try handle.close()
        } catch {
            // 閉じ切れなかった書きかけは捨てる。行き先の前のファイルはそのまま (#3426)
            try? FileManager.default.removeItem(atPath: writtenPath)
            throw .writeFailed(path: path, reason: Diagnostics.failureText(error))
        }
        // **閉じ終えたら、1 回の置き換えで行き先に置く** (#3426)。置けなかったら一時ファイルは `Placement` が消す
        if let placement {
            do {
                try placement.placeWritten()
            } catch {
                throw .writeFailed(path: path, reason: Diagnostics.failureText(error))
            }
        }
    }

    /// 書き損じた録りを捨てる。**一時ファイルを消す。行き先には触れない** (#3426)。
    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(atPath: writtenPath)
    }

    /// ImageIO に、1 枚だけの GIF を作らせる。
    private static func encodeSingle(_ picture: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.gif.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// sRGB の 8 ビット絵を、色空間つきの `CGImage` にする。**アルファは乗算していない (straight)。**
    ///
    /// - Parameter withAlpha: アルファを持つ絵として渡すか。透けた画素が無い枚は持たない。
    static func cgImage(of image: DisplayImage, withAlpha: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: (withAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast).rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// GIF の枚数を数える。読めなければ `nil`。
    static func frameCount(atPath path: String) -> Int? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            CGImageSourceGetType(source) as String? == UTType.gif.identifier
        else { return nil }
        return CGImageSourceGetCount(source)
    }
}

/// GIF の枠。**1 枚だけの GIF から、色表と画素の圧縮列を取り出し、複数枚の GIF の 1 枚として組み直す** ([#2440])。
///
/// GIF は、頭 (署名・画面の大きさ) と、枚ごとの 〔制御 (遅延・透けの印・消し方)・画像の記述・色表・圧縮列〕、
/// 終わりの印でできている。圧縮列 (LZW) はそのまま移せるので、**画素を圧縮し直さない**。取り出すのは
/// ImageIO が作った 1 枚だけの GIF で、枚ごとの色表をその枚の局所の色表として持つ。
nonisolated struct GIFBlocks: Equatable {
    /// 色表の生のバイト (3 バイト × 色の数)。
    var colorTable: [UInt8]
    /// 画像の記述の、位置と大きさ (左・上・幅・高さ)。
    var left: UInt16
    var top: UInt16
    var width: UInt16
    var height: UInt16
    /// 透けた色の番号 (透けの無い枚は `nil`)。
    var transparentIndex: UInt8?
    /// LZW の最小の符号長 + 圧縮列の小分け + 終わりの 0。**そのまま写す。**
    var imageData: [UInt8]

    /// 1 枚だけの GIF から取り出す。読めなければ `nil`。
    static func parse(_ data: Data) -> GIFBlocks? {
        let bytes = [UInt8](data)
        guard bytes.count > 13, bytes[0...2] == [0x47, 0x49, 0x46] else { return nil }  // "GIF"
        let packed = bytes[10]
        var cursor = 13
        var globalTable: [UInt8] = []
        if packed & 0x80 != 0 {
            let size = 3 * (1 << (Int(packed & 0x07) + 1))
            guard cursor + size <= bytes.count else { return nil }
            globalTable = Array(bytes[cursor..<cursor + size])
            cursor += size
        }
        var transparent: UInt8?
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 0x21:  // 拡張
                guard cursor + 2 < bytes.count else { return nil }
                let label = bytes[cursor + 1]
                cursor += 2
                if label == 0xF9, cursor + 5 < bytes.count, bytes[cursor] == 4 {
                    // 制御: 小分け長 4、packed、遅延 2、透けた番号、終わり 0
                    if bytes[cursor + 1] & 0x01 != 0 { transparent = bytes[cursor + 4] }
                }
                // 小分けを飛ばす
                guard let next = skipSubBlocks(bytes, from: cursor) else { return nil }
                cursor = next
            case 0x2C:  // 画像
                guard cursor + 10 < bytes.count else { return nil }
                let left = UInt16(bytes[cursor + 1]) | UInt16(bytes[cursor + 2]) << 8
                let top = UInt16(bytes[cursor + 3]) | UInt16(bytes[cursor + 4]) << 8
                let width = UInt16(bytes[cursor + 5]) | UInt16(bytes[cursor + 6]) << 8
                let height = UInt16(bytes[cursor + 7]) | UInt16(bytes[cursor + 8]) << 8
                let local = bytes[cursor + 9]
                // 飛び飛びに並べる (interlace) 画像は、並びを写すだけなので、そのまま扱える (印も写す)
                guard local & 0x40 == 0 else { return nil }
                cursor += 10
                var table = globalTable
                if local & 0x80 != 0 {
                    let size = 3 * (1 << (Int(local & 0x07) + 1))
                    guard cursor + size <= bytes.count else { return nil }
                    table = Array(bytes[cursor..<cursor + size])
                    cursor += size
                }
                guard !table.isEmpty, cursor < bytes.count else { return nil }
                // 最小の符号長 (1 バイト) の後ろの小分けを、終わりの 0 まで
                guard let end = skipSubBlocks(bytes, from: cursor + 1) else { return nil }
                return GIFBlocks(
                    colorTable: table, left: left, top: top, width: width, height: height,
                    transparentIndex: transparent, imageData: Array(bytes[cursor..<end]))
            case 0x3B:
                return nil
            default:
                return nil
            }
        }
        return nil
    }

    /// 小分け (長さ 1 バイト + 中身) を、終わりの 0 の次まで飛ばす。壊れていれば `nil`。
    private static func skipSubBlocks(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            let length = Int(bytes[cursor])
            cursor += 1
            if length == 0 { return cursor }
            cursor += length
        }
        return nil
    }

    /// 頭: 署名・画面の大きさ (全体の色表は持たない)・繰り返し無限の印。
    static func header(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = Array("GIF89a".utf8)
        bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
        // 全体の色表なし・色の深さ 8 ビット。背景の色の番号 0・縦横比 0
        bytes += [0x70, 0x00, 0x00]
        // 繰り返し (NETSCAPE2.0): 0 は無限
        bytes += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        return Data(bytes)
    }

    /// 終わりの印。
    static let trailer = Data([0x3B])

    /// 1 枚ぶん。**遅延は 1/100 秒。** 透けのある枚は、描く前に前の絵を消す (消し方 2) —
    /// 消さないと、透けた所に前の枚が残る。
    func frame(delay: Int) -> Data {
        var bytes: [UInt8] = []
        let disposal: UInt8 = transparentIndex == nil ? 1 : 2
        let flag: UInt8 = transparentIndex == nil ? 0 : 1
        bytes += [0x21, 0xF9, 0x04, (disposal << 2) | flag]
        bytes += [UInt8(delay & 0xFF), UInt8((delay >> 8) & 0xFF), transparentIndex ?? 0, 0x00]
        bytes += [0x2C]
        bytes += [UInt8(left & 0xFF), UInt8(left >> 8), UInt8(top & 0xFF), UInt8(top >> 8)]
        bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
        // 局所の色表あり。大きさは色の数 (2 の累乗) から求める
        let entries = colorTable.count / 3
        var sizeBits: UInt8 = 0
        while (2 << Int(sizeBits)) < entries { sizeBits += 1 }
        bytes += [0x80 | sizeBits]
        bytes += colorTable
        bytes += imageData
        return Data(bytes)
    }
}
