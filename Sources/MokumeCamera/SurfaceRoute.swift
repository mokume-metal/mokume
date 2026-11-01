// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import MokumeCore
import Synchronization

/// 届いた 1 枚。CPU で変換した ``DisplayImage`` か、面のまま GPU で色を変換する ``PixelSurface`` か。
///
/// 動画とカメラの入れ物 (``ExternalInput``) が運ぶ値。どちらで届いても、絵に書いた結果は 1 bit も違わない
/// ([#2962](https://github.com/mokume-metal/mokume/issues/2962))。
nonisolated enum VideoFrame: Sendable {
    case converted(DisplayImage)
    case surface(PixelSurface)

    /// 絵へ書く。
    @MainActor func write(to image: Image) {
        switch self {
        case .converted(let picture): image.write(picture)
        case .surface(let surface): image.write(surface)
        }
    }
}

/// 届いたコマを面のまま絵へ渡せるか (#2962)。渡せなければ、今までどおり CPU で ``DisplayImage`` にする。
///
/// ## 面に乗せる条件
///
/// - 面 (`IOSurface`) の裏付きの、32 bit の BGRA のコマ
/// - **不透明** — 画素を読まずに決める。動画は付帯の `AlphaChannelIsOpaque` が真のとき (復号器が付ける)、
///   カメラはいつも (``FrameConverter/Alpha/opaque``)
/// - **検証した色の意味** (``ColorMeaning``) — 付帯の組が許可の一覧に当たるとき。未知の ICC・HDR などは CPU
/// - 向きを当てない・鏡映しない (変換の後に CPU で画素を動かす仕事が残るため)
/// - 受け手が期待する大きさと同じ — 違えば変換器が縮めるので面には乗せない。**この判定は ``surface(for:alpha:reshaped:expecting:builds:tables:)`` が
///   自分で行う** (呼び出し側が `reshaped` に混ぜると、足し忘れた呼び出し元で面の絵が大きさの不一致を捨てる・#3690)
/// - その色の意味の表が既にある (``SurfaceTables``)。表は作るのに数十 ms かかるので、main では作らない
nonisolated enum SurfaceRoute {
    /// 面に乗せなかった理由。**検査が読む** (どちらの道を通ったか)。
    enum Refusal: Error, Equatable, Sendable {
        /// 計測が、変更前の CPU の道を測るために面の道を閉じている (``isEnabled``)。
        case disabled
        case noSurface
        case notBGRA
        case notOpaque
        case unverifiedColor
        case reshaped
        /// コマの大きさが受け手の期待と違う。変換器が縮めるので、面の絵には書かせない (#3690)。
        case resized
        case tableRejected
        case tablePending
    }

    /// 面の道を開いているか。**計測が倒す** (同じ実行の中で、変更前の CPU の道と並べる)。
    static let isEnabled = Atomic<Bool>(true)

    /// `buffer` を面のまま渡せるなら面の値を、渡せなければ理由を返す。
    ///
    /// - Parameters:
    ///   - alpha: 変換器の不透明度の扱い (動画は `.straight`、カメラは `.opaque`)。
    ///   - reshaped: 向き・鏡映・検査の変換のどれかを当てるか。当てるなら面に乗せない。
    ///   - size: 受け手が期待する大きさ (画素。変換器の記録の大きさ)。**`buffer` の大きさが違えば乗せない。**
    ///     面の絵 (``Image/write(_:)-(PixelSurface)``) は大きさの不一致を警告して捨てるが、変換器は縮めて渡すため。
    ///   - builds: 表が無いとき、ここで作るか。**main からは `false`** (作るのは先読みの係とカメラの絵の列)。
    static func surface(
        for buffer: CVPixelBuffer, alpha: FrameConverter.Alpha, reshaped: Bool, expecting size: (width: Int, height: Int),
        builds: Bool, tables: SurfaceTables = .shared
    ) -> Result<PixelSurface, Refusal> {
        guard isEnabled.load(ordering: .relaxed) else { return .failure(.disabled) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return .failure(.notBGRA) }
        guard let reference = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            return .failure(.noSurface)
        }
        guard !reshaped else { return .failure(.reshaped) }
        guard CVPixelBufferGetWidth(buffer) == size.width, CVPixelBufferGetHeight(buffer) == size.height else {
            return .failure(.resized)
        }
        guard alpha == .opaque || declaresOpaque(buffer) else { return .failure(.notOpaque) }
        guard let meaning = ColorMeaning(buffer) else { return .failure(.unverifiedColor) }
        let table: PixelSurface.ColorTable
        switch tables.table(for: SurfaceTables.Key(meaning: meaning, alpha: alpha), from: buffer, builds: builds) {
        case .success(let made): table = made
        case .failure(let refusal): return .failure(refusal)
        }
        // IOSurfaceRef と IOSurface は同じものを指す (toll-free bridged)
        let surface = unsafeBitCast(reference, to: IOSurface.self)
        guard let frame = PixelSurface(surface, conversion: table) else { return .failure(.notBGRA) }
        return .success(frame)
    }

    /// 復号器が「不透明」と名乗っているか (`AlphaChannelIsOpaque`)。
    static func declaresOpaque(_ buffer: CVPixelBuffer) -> Bool {
        guard let value = CVBufferCopyAttachment(buffer, "AlphaChannelIsOpaque" as CFString, nil) else { return false }
        return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true
    }
}

/// 色の意味を決める付帯の組。**検証した組だけを作れる** (それ以外は `init` が `nil`)。
///
/// 表は、この組を写した 256×256 の絵を本物の変換器に通して作るので、同じ組のコマは表で引いても変換器と
/// 同じ色になる。組には色の変換に効く付帯を全部入れる (変換器の vImage は色空間・原色・伝達関数を読む)。
nonisolated struct ColorMeaning: Hashable, Sendable {
    /// 検証した色の意味。
    enum Kind: Hashable, Sendable {
        /// ファイルが色を名乗らず、復号器が推した (`ColorInfoGuessedBy`)。#2962 の「付帯なし」に当たる
        case guessed
        /// 付帯が何も無い (変換器は sRGB とみなす)。
        case none
        /// sRGB の色空間を名乗る。
        case sRGB
        /// Display P3 の色空間を名乗る。
        case displayP3
        /// Rec.709 の原色と伝達関数を名乗る。
        case rec709
    }

    let kind: Kind
    let primaries: String?
    let transfer: String?
    let matrix: String?
    /// 色空間の付帯の ICC (名前を持たない ICC の色空間を見分けるため)。
    let colorSpaceICC: Data?
    let colorSpaceName: String?

    init?(_ buffer: CVPixelBuffer) {
        func string(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil).flatMap { $0 as? String }
        }
        primaries = string(kCVImageBufferColorPrimariesKey)
        transfer = string(kCVImageBufferTransferFunctionKey)
        matrix = string(kCVImageBufferYCbCrMatrixKey)
        let space = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil)
            .map { $0 as! CGColorSpace }  // 付帯の型は CGColorSpace と決まっている
        colorSpaceName = space?.name as String?
        colorSpaceICC = space?.copyICCData() as Data?
        // 伝達関数をガンマで名乗る付帯・ICC の付帯は、検証していない
        let gamma = CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil)
        let icc = CVBufferCopyAttachment(buffer, kCVImageBufferICCProfileKey, nil)
        guard gamma == nil, icc == nil else { return nil }
        let guessed = CVBufferCopyAttachment(buffer, "ColorInfoGuessedBy" as CFString, nil) != nil
        let rec709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        let transfer709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        if guessed {
            kind = .guessed
        } else if primaries == nil, transfer == nil, space == nil {
            kind = .none
        } else if primaries == nil, transfer == nil, colorSpaceName == CGColorSpace.sRGB as String {
            kind = .sRGB
        } else if primaries == nil, transfer == nil, colorSpaceName == CGColorSpace.displayP3 as String {
            kind = .displayP3
        } else if primaries == rec709, transfer == transfer709 {
            kind = .rec709
        } else {
            return nil
        }
    }
}

/// 色の意味と不透明度の扱いごとに、面の色の表 (``PixelSurface/ColorTable``) を作って持ち回す。プロセスに 1 つ。
///
/// **表は本物の変換器 (``FrameConverter``) で作る** — 届いたコマの付帯を 256×256 の BGRA の絵へ写し、青の値
/// ごとに 256 回変換する (#2802 の試作と同じ)。だから表で引いた色は、同じコマを変換器に通した色と同じになる。
/// 作るのに数十 ms (release) かかるので、作るのは先読みの係とカメラの絵の列の上だけにし、main は出来ている表を
/// 使うだけにする。作れなかった (詰め方の性質を満たさない) ことも覚え、作り直さない。
nonisolated final class SurfaceTables: Sendable {
    static let shared = SurfaceTables()

    struct Key: Hashable, Sendable {
        let meaning: ColorMeaning
        let alpha: FrameConverter.Alpha
    }

    private enum Entry {
        case building
        case ready(PixelSurface.ColorTable)
        case rejected
    }

    private let entries = Mutex<[Key: Entry]>([:])
    /// 表を作った回数。**検査が読む** (main で作っていないか・作り直していないか)。
    let built = Atomic<Int>(0)

    init() {}

    /// `key` の表。無ければ、`builds` なら `buffer` の付帯でここで作る。
    func table(for key: Key, from buffer: CVPixelBuffer, builds: Bool) -> Result<PixelSurface.ColorTable, SurfaceRoute.Refusal> {
        let claimed = entries.withLock { entries -> Result<PixelSurface.ColorTable, SurfaceRoute.Refusal>? in
            switch entries[key] {
            case .ready(let table): return .success(table)
            case .rejected: return .failure(.tableRejected)
            case .building: return .failure(.tablePending)
            case nil:
                guard builds else { return .failure(.tablePending) }
                entries[key] = .building
                return nil
            }
        }
        if let claimed { return claimed }
        let made = Self.build(from: buffer, alpha: key.alpha)
        built.add(1, ordering: .relaxed)
        entries.withLock { $0[key] = made.map(Entry.ready) ?? .rejected }
        return made.map(Result.success) ?? .failure(.tableRejected)
    }

    /// 付帯を写した 256×256 の絵を、青の値ごとに変換器へ通して表を作る。
    static func build(from buffer: CVPixelBuffer, alpha: FrameConverter.Alpha) -> PixelSurface.ColorTable? {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA, nil, &made) == kCVReturnSuccess,
            let probe = made
        else { return nil }
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) {
            CVBufferSetAttachments(probe, attachments, .shouldPropagate)
        }
        if let attachments = CVBufferCopyAttachments(buffer, .shouldNotPropagate) {
            CVBufferSetAttachments(probe, attachments, .shouldNotPropagate)
        }
        let converter = FrameConverter(width: 256, height: 256, alpha: alpha)
        return try? PixelSurface.ColorTable { blue in
            CVPixelBufferLockBaseAddress(probe, [])
            let base = CVPixelBufferGetBaseAddress(probe)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(probe)
            for green in 0..<256 {
                let row = base.advanced(by: green * rowBytes)
                for red in 0..<256 {
                    // BGRA の並び
                    row[red * 4] = UInt8(blue)
                    row[red * 4 + 1] = UInt8(green)
                    row[red * 4 + 2] = UInt8(red)
                    row[red * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(probe, [])
            return try converter.convert(probe).bytes
        }
    }
}
