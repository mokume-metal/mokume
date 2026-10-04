// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

// 製品の原文を読み、**細かさを下げた面の出す先 (`Canvas.output`) を読む行が、どう追い付くかを
// 名乗っているか**を見る ([#2104])。`StoppedUpscaleOutletsTests` が実際に読んで確かめる口の、
// 原文の側の登録簿である。
//
// ## なぜ要るか
//
// 細かさを下げた面をフレームの外で描き切ると、描く先だけが変わって出す先は古いまま残り
// (`Canvas.targetChangedSinceUpscale` が立つだけ)、**出す先を読む側がそれぞれ追い付く**約束に
// なっている。追い付く口は個別に足されてきた — 出力段と CPU の読み出し ([#1882])、置く口
// ([#2042])。書く側には関所 (`Canvas.settlePlacersBeforeChange()`) と debug の検算
// (`RenderTarget.assertPlacersSettledBeforeWriting()`) があるが、読む側には無い。出す先を読む口を
// この外に足すと、細かさ 0.5 の面だけ古い絵が出る症状が黙って再発する。実行時の検算は、正しい
// 古い読み (置いた時点の絵 [#1656]) まで止めてしまうので、原文で見る ([#2104] の決定)。
//
// ## 追い付き方は 4 通りある
//
// - **置く口**: 描き場所に面を置く口は、置いた時点で `Canvas.note(placing:)` が追い付かせる
// - **読む口**: 出力段 (`RenderTarget.encodeToImage()` ほか) と `readPixels()` は、頭で
//   `RenderTarget.catchUpWithDrawnPicture()` を通る
// - **ランタイムの配った後**: 窓と共有の面は出す先のテクスチャを直に読み、止まっている間の
//   コールバックを配った直後の `Canvas.catchUpOutputWithoutThrowing()` (`SketchRuntime.advance()`)
//   に頼る
// - **わざと古い**: 置いた時点の写し ([#1656]) や時間方向の履歴のように、古い絵を読むのが約束
//
// ## 規則
//
// > `Sources/` で下の綴り (``tokens``) が出る行は、ファイルと綴りの組ごとに一覧にあり、
// > 行の数が一致し、追い付き方と理由を名乗る。
//
// 行番号では照合しない — 関係の無い編集で赤くならないように、ファイル・綴り・行の数で見る。
// 新しい行を足したら、追い付きを通してから一覧に理由ごと足す。理由を書けない行は、追い付いて
// いないということである。
//
// **コメントだけの行は数えない** (`//` で始まる行)。読む口を説明する doc が綴りに触れるたびに
// 一覧を足すことになるからである。行末のコメントを持つコードの行は数える。
//
// **綴りは 2026-10-05 時点で出す先を読む全経路を `rg` で確かめて決めた。** 出す先を名指す式
// (`output.texture`・ランタイムの `runtime.target`)、描き場所の出す先から作る絵 (`.drawn(`)、
// テクスチャを標本にする口 (`.setSource(`) である。出す先を新しい綴りで読む口を足すときは、
// ``tokens`` にも足す。`readPixels()` は出す先のテクスチャを写しへ読み戻す口で、どの綴りにも
// 現れない (写しを経る `pixels` と経路を分け合うので、綴りに足すと出す先でない面の読みまで拾う)。
// 頭の追い付きは `StoppedUpscaleOutletsTests` が実際に読んで確かめる。
//
// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
// [#2104]: https://github.com/mokume-metal/mokume/issues/2104

/// 出す先を読む行が、読む口の登録簿に追い付き方ごと載っているかを原文から見る。
///
/// GPU を使わない。`StoppedUpscaleOutletsTests` は GPU の無い環境でスキップされるので、原文の
/// 検査は別の suite に置いて、どこでも走らせる。
@Suite("細かさを下げた面の出す先を読む行の登録簿")
struct StoppedUpscaleOutletReadersTests {
    /// 出す先を読む行が名乗れる追い付き方。
    private enum CatchUp: CustomStringConvertible {
        /// 置く口。置いた時点で `Canvas.note(placing:)` が追い付かせる ([#2042])。
        ///
        /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
        case placing
        /// 読む口。頭で `RenderTarget.catchUpWithDrawnPicture()` を通る ([#1882])。
        ///
        /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
        case reading
        /// ランタイムの配った後。止まっている間のコールバックを配った直後に
        /// `Canvas.catchUpOutputWithoutThrowing()` が追い付かせる ([#1882]・[#1906])。
        ///
        /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
        /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
        case afterDelivery
        /// わざと古い。追い付かずに読むのが約束で、理由にその約束を書く。
        case deliberatelyStale

        /// 名乗りが本当かを原文から見るための綴り。無ければ理由だけを見る。
        var evidence: String? {
            switch self {
            case .placing: "note(placing:"
            case .reading: "catchUpWithDrawnPicture()"
            case .afterDelivery: "catchUpOutputWithoutThrowing()"
            case .deliberatelyStale: nil
            }
        }

        var description: String {
            switch self {
            case .placing: "置く口"
            case .reading: "読む口"
            case .afterDelivery: "ランタイムの配った後"
            case .deliberatelyStale: "わざと古い"
            }
        }
    }

    /// 出す先を読む綴りと、その名前 (一覧の照合と赤のときの案内に使う)。
    ///
    /// `\b` は単純な語の境目で読む (``matching(_:)``)。既定の Unicode の境目は `graphics.output` を
    /// 1 語と見なし、`graphics.output.texture` の `output` の前に境目を置かない。
    private static let tokens: [(name: String, pattern: Regex<Substring>)] = [
        // 描き場所の出す先から作る絵と、その絵を読む側
        (".drawn(", /\.drawn\(/),
        // 描き場所の出す先のテクスチャを名指す
        ("output.texture", /\boutput\.texture\b/),
        // ランタイムの出す先を、大きさ以外のために渡す (大きさは絵を読まない)
        ("runtime.target", /\bruntime\.target\b(?!\.(?:width|height)\b)/),
        // テクスチャを標本にする口へ渡す (出力段・窓と共有の面)
        (".setSource(", /\.setSource\(/),
    ]

    private static func matching(_ pattern: Regex<Substring>) -> Regex<Substring> {
        pattern.wordBoundaryKind(.simple)
    }

    /// 出す先を読んでよい行と、その追い付き方。
    ///
    /// `file` は `Sources/` からの道のり。`count` はそのファイルでその綴りが出る行の数。`catchUp` の
    /// 裏は ``CatchUp/evidence`` を `vouchedIn` (省けば同じファイル) の原文で取る。同じファイルで
    /// 裏を取るときは、裏の綴りが行の数以上あることまで見る — 置く口を 1 つ足して記録を忘れると、
    /// 数が足りなくなる。
    private struct Reader {
        let file: String
        let token: String
        let count: Int
        let catchUp: CatchUp
        var vouchedIn: String? = nil
        let reason: String
    }

    private static let readers: [Reader] = [
        // MARK: 置く口
        Reader(
            file: "MokumeCore/Drawing/Canvas+Image.swift", token: ".drawn(", count: 4,
            catchUp: .placing,
            reason: "texture(canvas) と image(canvas) の 3 形。どれも絵を作る直前に note(placing: graphics) を通す (#2042)"),
        Reader(
            file: "MokumeCore/Drawing/ShaderSurface.swift", token: ".drawn(", count: 1,
            catchUp: .placing, vouchedIn: "MokumeCore/Drawing/Canvas+Style.swift",
            reason: "断片の面に渡した描き場所。置くたびに Canvas+Style の notePaintPlacement が drawnSurfaces を note(placing:) で記録する"),
        Reader(
            file: "MokumeCore/Drawing/Shader.swift", token: ".drawn(", count: 2,
            catchUp: .placing, vouchedIn: "MokumeCore/Drawing/Canvas+Style.swift",
            reason: "断片の面から描き場所を抜き出して控える (drawnSurfaces)。読むのは置く口で、Canvas+Style の notePaintPlacement が note(placing:) で記録する"),
        Reader(
            file: "MokumeCore/Drawing/Picture.swift", token: ".drawn(", count: 4,
            catchUp: .placing, vouchedIn: "MokumeCore/Drawing/Canvas.swift",
            reason: "置く口が作った絵の大きさと面を読む。面を切り替える useTexture が持ち主の描き場所を note(placing:) で記録する (#1543)"),
        // MARK: 読む口
        Reader(
            file: "MokumeCore/Output/RenderTarget+Output.swift", token: ".setSource(", count: 1,
            catchUp: .reading,
            reason: "出力段 (encodeToImage・encodeForDisplay・writePNG)。組む前に catchUpWithDrawnPicture() を通る (#1882)"),
        // MARK: ランタイムの配った後
        Reader(
            file: "MokumeCore/Display/SketchApplication.swift", token: "runtime.target", count: 2,
            catchUp: .afterDelivery, vouchedIn: "MokumeCore/Sketch/SketchRuntime.swift",
            reason: "窓 (presenter.present) と共有の面 (shared.write)。advance() がコールバックを配った直後と止めている間に catchUpOutputWithoutThrowing() を済ませた後に呼ぶ (#1882・#1906)"),
        Reader(
            file: "MokumeCore/Display/FramePresenter.swift", token: ".setSource(", count: 1,
            catchUp: .afterDelivery, vouchedIn: "MokumeCore/Sketch/SketchRuntime.swift",
            reason: "窓と共有の面が出す先のテクスチャを標本にする。渡されるのは上の runtime.target だけで、配った直後の追い付きの後に読む"),
        // MARK: わざと古い
        Reader(
            file: "MokumeCore/Drawing/Canvas.swift", token: "output.texture", count: 2,
            catchUp: .deliberatelyStale,
            reason: "置いた時点の絵の写し (copyPlacedPicture・#1656)。相手の出す先が変わる直前に、置いた時点のまま写すのが約束。追い付く前の絵を写す"),
        Reader(
            file: "MokumeCore/Drawing/Canvas+Upscale.swift", token: "output.texture", count: 1,
            catchUp: .deliberatelyStale,
            reason: "時間方向の履歴。拡大で書いた直後の出す先を、次のフレームが混ぜる相手として控える。止まっている間の追い付きは履歴を動かさない (catchUpOutput)"),
    ]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ
            .appending(path: "Sources")
    }

    /// 1 行。赤のときの案内に行番号を添えるためだけに持つ (照合には使わない)。
    private struct Line {
        let number: Int
        let text: String
    }

    /// `Sources/` の Swift の原文を、コメントだけの行を除いて読む。
    private func codeLines() throws -> [String: [Line]] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(!names.isEmpty, "製品の原文が 1 つも見つからない (\(sourceRoot.path))")
        var files: [String: [Line]] = [:]
        for name in names {
            let source = try String(contentsOf: sourceRoot.appending(path: name), encoding: .utf8)
            files[name] = source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { Line(number: $0.offset + 1, text: String($0.element)) }
        }
        return files
    }

    private struct Key: Hashable {
        let file: String
        let token: String
    }

    /// ファイルと綴りの組ごとに、綴りが出る行。
    private func readingLines(in files: [String: [Line]]) -> [Key: [Line]] {
        var found: [Key: [Line]] = [:]
        for (file, lines) in files {
            for token in Self.tokens {
                let pattern = Self.matching(token.pattern)
                let hits = lines.filter { $0.text.contains(pattern) }
                if !hits.isEmpty { found[Key(file: file, token: token.name), default: []] += hits }
            }
        }
        return found
    }

    @Test("出す先を読む行は、すべて一覧に載っている")
    func everyReaderIsListed() throws {
        let found = readingLines(in: try codeLines())
        let listed = Set(Self.readers.map { Key(file: $0.file, token: $0.token) })
        let unlisted = found.filter { !listed.contains($0.key) }
            .sorted { ($0.key.file, $0.key.token) < ($1.key.file, $1.key.token) }
        #expect(
            unlisted.isEmpty,
            """
            細かさを下げた面の出す先を読んでいるのに、読む口の登録簿に無い:

            \(unlisted.flatMap { entry in
                entry.value.map { "Sources/\(entry.key.file):\($0.number) (\(entry.key.token))" }
            }.joined(separator: "\n"))

            読む前に追い付かせ (置く口なら note(placing:) を通す / 出す先を読む口なら頭で
            catchUpWithDrawnPicture() を通す)、StoppedUpscaleOutletReadersTests.readers に
            追い付き方と理由ごと足す。追い付かずに読むのが約束なら、わざと古いと名乗って約束を書く。
            """)
    }

    @Test("一覧の行は、まだ原文にあり、数が合い、名乗ったとおり追い付く")
    func everyReaderIsHonest() throws {
        let files = try codeLines()
        let found = readingLines(in: files)
        for reader in Self.readers {
            let lines = found[Key(file: reader.file, token: reader.token)] ?? []
            #expect(
                lines.count == reader.count,
                """
                Sources/\(reader.file) で \(reader.token) が出る行は \(lines.count) 行だが、一覧は \
                \(reader.count) 行と名乗る: \(lines.map(\.number))
                増えたなら追い付きを通してから数と理由を直す。消えたなら一覧から外す。
                """)
            #expect(
                !reader.reason.trimmingCharacters(in: .whitespaces).isEmpty,
                "Sources/\(reader.file) の \(reader.token) は \(reader.catchUp) と名乗るが、理由が無い")
            guard let evidence = reader.catchUp.evidence else { continue }
            let vouching = reader.vouchedIn ?? reader.file
            let witnesses = (files[vouching] ?? []).filter { $0.text.contains(evidence) }.count
            let needed = reader.vouchedIn == nil ? reader.count : 1
            #expect(
                witnesses >= needed,
                """
                Sources/\(reader.file) の \(reader.token) は \(reader.catchUp) と名乗るが、\
                Sources/\(vouching) のコードに \(evidence) が \(witnesses) 回しか無い (\(needed) 回以上要る)
                """)
        }
    }

    @Test("一覧はファイルと綴りの組ごとに 1 行で、綴りは決めたものだけ")
    func readersAreWellFormed() {
        let keys = Self.readers.map { Key(file: $0.file, token: $0.token) }
        #expect(Set(keys).count == keys.count, "一覧に同じファイルと綴りの組が 2 行ある")
        let names = Set(Self.tokens.map(\.name))
        for reader in Self.readers {
            #expect(names.contains(reader.token), "\(reader.file) の綴り \(reader.token) は tokens に無い")
            #expect(reader.count > 0, "\(reader.file) の \(reader.token) の行の数が 0 以下")
        }
    }
}
