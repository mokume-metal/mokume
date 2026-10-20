// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// ファイルから書体を読む口 (`loadFont`・`textFont(_: Font)`) と、太さ (`textWeight`) の検査 ([#2445])。
///
/// **検査に使う書体は、この Mac に同梱のもの** — リポジトリに書体のファイルは置かない
/// (帰属の宣言が要るため)。可変書体は `SFNS.ttf` (システム書体・`wght` 軸は 1…1000)、可変でない書体は
/// `Helvetica.ttc` (Light・Regular・Bold とそれぞれの斜体の 6 面)。
///
/// この suite は GPU を使わない。`Typeface` を直接作り、字の送り幅と、引いた面で見る。Canvas を通る
/// 検査 (鍵の丸め・後勝ち・警告) は ``FontFileCanvasTests``。
///
/// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
@Suite("書体のファイル")
struct FontFileTests {
    static let variableFile = "/System/Library/Fonts/SFNS.ttf"
    static let staticFile = "/System/Library/Fonts/Helvetica.ttc"

    /// 引き当ての知らせは、この検査では見ない。
    private static func typeface(
        file: Font? = nil, name: String? = nil, style: TextStyle = .normal, weight: Int? = nil,
        size: Float = 40
    ) -> Typeface {
        Typeface(
            request: TypefaceRequest(name: name, file: file, size: size, style: style, weight: weight)
        ) { _, _, _ in }
    }

    /// 読んだ書体で、文字列の送り幅。`FontFileCanvasTests` が、面を通した値と突き合わせる。
    static func typefaceWidth(of string: String, file: Font, size: Float) -> Float {
        typeface(file: file, size: size).advance(of: string)
    }

    private static func postScript(_ face: Typeface) -> String {
        CTFontCopyPostScriptName(face.base) as String
    }

    /// 面が今いる `wght` 軸の値。軸を持たなければ `nil`。
    private static func weightValue(_ font: CTFont) -> Double? {
        let variation = CTFontCopyVariation(font) as NSDictionary?
        return (variation?[NSNumber(value: TypefaceWeight.axisIdentifier)] as? NSNumber)?.doubleValue
    }

    // MARK: - 読む

    @Test("可変書体のファイルは、面を 1 つだけ持つ可変書体として読める")
    func aVariableFileIsOneVariableFace() throws {
        let font = try Font.load(Self.variableFile)
        #expect(font.isVariable)
        #expect(font.faces.count == 1, "名前つきのインスタンスの全部を面にした")
    }

    @Test("可変でないファイルは、持つ面の全部を読む")
    func aStaticFileKeepsEveryFace() throws {
        let font = try Font.load(Self.staticFile)
        #expect(!font.isVariable)
        #expect(font.faces.count == 6)
    }

    @Test("同じファイルを更新されないまま読み直しても、等しい値になる")
    func theSameFileIsTheSameValue() throws {
        let first = try Font.load(Self.staticFile)
        let second = try Font.load(Self.staticFile)
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        let other = try Font.load(Self.variableFile)
        #expect(first != other)
    }

    /// 更新時刻が変わったファイルは、別の値 (焼き場が古い字形を使い回さない)。
    @Test("ファイルが更新されると、別の値になる")
    func aChangedFileIsAnotherValue() throws {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-font-\(UUID().uuidString).ttc")
        try FileManager.default.copyItem(atPath: Self.staticFile, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        let before = try Font.load(copy.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: copy.path)
        let after = try Font.load(copy.path)
        #expect(before != after)
    }

    @Test("無いパスは notFound で、探した場所を名乗る")
    func aMissingPathSaysWhereItLooked() {
        let path = "assets/fonts/does-not-exist-\(UUID().uuidString).otf"
        do {
            _ = try Font.load(path)
            Issue.record("読めてしまった")
        } catch {
            guard case .notFound(let named, let searched) = error else {
                Issue.record("notFound ではない: \(error)")
                return
            }
            #expect(named == path)
            #expect(!searched.isEmpty)
            #expect(error.description.contains("Looked in"))
        }
    }

    @Test("書体でないファイルは unreadable")
    func aNonFontFileIsUnreadable() {
        #expect(throws: FontFailure.unreadable(path: "/etc/hosts")) {
            _ = try Font.load("/etc/hosts")
        }
    }

    @Test("ディレクトリは、書体でないとは言わず unopenable で場所を名乗る")
    func aDirectoryIsUnopenable() {
        do {
            _ = try Font.load("/System/Library/Fonts")
            Issue.record("読めてしまった")
        } catch {
            guard case .unopenable(let path, let location, let reason) = error else {
                Issue.record("unopenable ではない: \(error)")
                return
            }
            #expect(path == "/System/Library/Fonts")
            #expect(location == "/System/Library/Fonts")
            #expect(reason.contains("directory"), "\(reason)")
        }
    }

    /// 登録してしまうと、同じ名前の書体を `textFont("名前")` が引いたとき、読んだファイルが答えうる。
    /// システムの書体は元から登録されているので、**この Mac のどこにも登録されていない場所へ写した
    /// ファイル**で見る。
    @Test("読んだ書体は、プロセスへ登録しない")
    func loadingDoesNotRegister() throws {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-font-\(UUID().uuidString).ttc")
        try FileManager.default.copyItem(atPath: Self.staticFile, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        try #require(
            CTFontManagerGetScopeForURL(copy as CFURL) == .none, "前提: 写したファイルは登録されていない")

        let font = try Font.load(copy.path)
        _ = Self.typeface(file: font, weight: 300).base
        #expect(CTFontManagerGetScopeForURL(copy as CFURL) == .none, "読んだファイルが登録された")
    }

    // MARK: - 既定の面

    /// 可変書体のファイルが返す記述子の先頭は、最も細い名前つきインスタンスである (実測)。何も頼まない
    /// 書体は、軸の既定値の面で描かなければならない。
    @Test("太さを頼まない可変書体は、軸の既定値 (400) の面で描く")
    func anUnweightedVariableFileUsesTheAxisDefault() throws {
        let font = try Font.load(Self.variableFile)
        let plain = Self.typeface(file: font)
        // 既定値の面は、400 を頼んだ面と同じ幅で、最も細い面 (100) とは違う
        #expect(plain.advance(of: "M") == Self.typeface(file: font, weight: 400).advance(of: "M"))
        #expect(plain.advance(of: "M") > Self.typeface(file: font, weight: 100).advance(of: "M"))
        #expect(plain.usedWeight == nil)
    }

    @Test("太字は 700 で描く")
    func boldIsSevenHundredOnAVariableFile() throws {
        let face = Self.typeface(file: try Font.load(Self.variableFile), style: .bold)
        #expect(Self.weightValue(face.base) == 700)
        #expect(face.advance(of: "M") == Self.typeface(file: try Font.load(Self.variableFile), weight: 700).advance(of: "M"))
        #expect(!face.lacksRequestedStyle)
    }

    // MARK: - 太さ (可変書体)

    @Test("既定の書体の 40 画素の M は、太さ 300 と 800 で送り幅が違い、800 で 35.2 前後になる")
    func theDefaultTypefaceWidensWithWeight() {
        let light = Self.typeface(weight: 300).advance(of: "M")
        let heavy = Self.typeface(weight: 800).advance(of: "M")
        // 版の違う OS の既定の書体でも収まるよう、幅は少し余裕を持たせる (Issue の実測は 800 で 35.2 前後)
        #expect(abs(light - 32.95) < 0.3, "300 で \(light)")
        #expect(abs(heavy - 35.2) < 0.3, "800 で \(heavy)")
        #expect(light < heavy)
    }

    @Test("ファイルの可変書体も、太さを軸へ届ける。太いほど送り幅が増える")
    func aVariableFileFollowsTheWeight() throws {
        let font = try Font.load(Self.variableFile)
        let widths = [100, 300, 500, 700, 900].map { Self.typeface(file: font, weight: $0).advance(of: "M") }
        #expect(widths == widths.sorted(), "\(widths)")
        #expect(Set(widths).count == widths.count, "同じ幅の太さがある: \(widths)")
        for weight in [100, 450, 900] {
            #expect(Self.weightValue(Self.typeface(file: font, weight: weight).base) == Double(weight))
        }
    }

    @Test("太さが軸の範囲を外れても、使った太さを返し、離れすぎなければ知らせない")
    func theUsedWeightIsReported() throws {
        let font = try Font.load(Self.variableFile)
        let face = Self.typeface(file: font, weight: 650)
        #expect(face.usedWeight == 650)
        #expect(!face.lacksRequestedWeight)
        // 太さを頼まなければ、使った太さは持たない
        #expect(Self.typeface(file: font).usedWeight == nil)
    }

    // MARK: - 太さ (可変でない書体)

    /// ファイルの 6 面から選ぶ。登録しないので、CoreText は兄弟の面を引けない。
    @Test(
        "可変でない書体のファイルは、最も近い太さの面を使う",
        arguments: [
            (100, TextStyle.normal, "Helvetica-Light"),
            (300, .normal, "Helvetica-Light"),
            (350, .normal, "Helvetica-Light"),
            (400, .normal, "Helvetica"),
            (500, .normal, "Helvetica"),
            (700, .normal, "Helvetica-Bold"),
            (900, .normal, "Helvetica-Bold"),
            (300, .italic, "Helvetica-LightOblique"),
            (700, .italic, "Helvetica-BoldOblique"),
            // 太さを頼めば、太字の指定は効かない
            (300, .bold, "Helvetica-Light"),
        ])
    func aStaticFileUsesTheNearestFace(_ item: (weight: Int, style: TextStyle, expected: String)) throws {
        let font = try Font.load(Self.staticFile)
        // Canvas は、太さを頼んだとき太字を落としてから請求する
        let style: TextStyle = item.style == .bold ? .normal : item.style
        let face = Self.typeface(file: font, style: style, weight: item.weight)
        #expect(Self.postScript(face) == item.expected, "太さ \(item.weight) \(item.style)")
    }

    @Test("太さを頼まなければ、太字・斜体は性質で面を選び、面があれば警告しない")
    func styleWithoutWeightPicksByTrait() throws {
        let font = try Font.load(Self.staticFile)
        for (style, expected) in [
            (TextStyle.normal, "Helvetica"), (.bold, "Helvetica-Bold"), (.italic, "Helvetica-Oblique"),
            (.boldItalic, "Helvetica-BoldOblique"),
        ] {
            let face = Self.typeface(file: font, style: style)
            #expect(Self.postScript(face) == expected, "\(style)")
            #expect(!face.lacksRequestedStyle, "\(style)")
            #expect(face.usedWeight == nil)
        }
    }

    @Test("近い面が無いほど離れた太さは、使った面を名乗れるよう印を立てる")
    func aFarWeightIsFlagged() throws {
        let font = try Font.load(Self.staticFile)
        let near = Self.typeface(file: font, weight: 500)
        #expect(near.usedWeight == 400)
        #expect(!near.lacksRequestedWeight, "500 に 400 を使う程度は面の粒度")
        let far = Self.typeface(file: font, weight: 900)
        #expect(far.usedWeight == 700)
        #expect(far.lacksRequestedWeight)
        #expect(Self.typeface(file: font, weight: 100).lacksRequestedWeight, "100 に 300 の面しか無い")
    }

    @Test("名前で引いた可変でない書体も、同じ家族から最も近い太さの面を使う")
    func aNamedStaticFamilyUsesTheNearestFace() {
        #expect(Self.postScript(Self.typeface(name: "Helvetica", weight: 300)) == "Helvetica-Light")
        #expect(Self.postScript(Self.typeface(name: "Helvetica", weight: 900)) == "Helvetica-Bold")
        #expect(
            Self.postScript(Self.typeface(name: "Helvetica", style: .italic, weight: 700))
                == "Helvetica-BoldOblique")
    }

    // MARK: - 焼き場の鍵

    /// 同じ PostScript 名のインストール済みの書体と、ファイルから読んだ書体が、同じ鍵で焼かれては
    /// ならない (ファイルが差し替わっても古い字形が出る)。
    @Test("ファイルの書体の字は、同じ名前のインストール済みの書体と別の鍵を持つ")
    func aFilesGlyphKeyIsNotTheInstalledOnes() throws {
        let file = try #require(Self.typeface(file: try Font.load(Self.staticFile)).glyph(for: "a"))
        let installed = try #require(Self.typeface(name: "Helvetica").glyph(for: "a"))
        #expect(file.glyph == installed.glyph, "前提: 同じ面の同じ字")
        #expect(file.fontKey != installed.fontKey, "\(file.fontKey)")
        #expect(file.fontKey.hasPrefix("Helvetica#"), "\(file.fontKey)")
    }
}
