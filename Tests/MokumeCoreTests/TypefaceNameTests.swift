// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import Testing

@testable import MokumeCore

/// 書体の各言語の名前の表 (#2563)。GPU を使わない。
///
/// **名前の引き方 (``TypefaceNameIndex``) は合成の材料で見る** — どの機械でも同じ結果になる。
/// **この環境の書体で見るもの**は、後ろの 2 本に分ける。前提が崩れたら黙って飛ばさず `#require` で赤くする。
@Suite("書体の各言語の名前")
struct TypefaceNameTests {
    // MARK: - 引き方 (合成の材料)

    /// 2 つのファミリー (Alpha は 2 面。**列挙の順は Bold が先**で、CoreText が選ぶ Regular と違う)。
    /// `アルファ` は Alpha のファミリー名。`ガンマ 太字` は Alpha-Bold のフルネームの 1 つ (濁点の検査用)。
    private static func faces() -> [TypefaceNameIndex.Face] {
        [
            .init(
                postScript: "Alpha-Bold", family: "Alpha",
                faceNames: ["Alpha-Bold", "Alpha Bold", "アルファ 太字", "ガンマ 太字"],
                familyNames: ["Alpha", "アルファ"]),
            .init(
                postScript: "Alpha-Regular", family: "Alpha",
                faceNames: ["Alpha-Regular", "Alpha Regular", "アルファ 標準"],
                familyNames: ["Alpha", "アルファ"]),
            .init(
                postScript: "Delta-Medium", family: "Delta",
                faceNames: ["Delta-Medium", "デルタ"],
                familyNames: ["Delta", "デルタ体"]),
        ]
    }

    /// ファミリー名で CoreText が選ぶ面。Alpha は列挙の順 (Bold が先) ではなく Regular を選ぶ。
    private static func index(
        defaultFace: @escaping (String) -> String? = {
            ["Alpha": "Alpha-Regular", "Delta": "Delta-Medium"][$0]
        }
    ) -> TypefaceNameIndex {
        TypefaceNameIndex(faces: faces(), defaultFace: defaultFace)
    }

    @Test("面の名前は、各言語のフルネームでもその面を引く", arguments: [
        ("アルファ 太字", "Alpha-Bold"),
        ("アルファ 標準", "Alpha-Regular"),
        ("Alpha Regular", "Alpha-Regular"),
        ("デルタ", "Delta-Medium"),
    ])
    func aFaceNameFindsItsFace(_ name: String, _ postScript: String) {
        #expect(Self.index().postScriptName(for: name) == postScript)
    }

    @Test("名前は、濁点の綴り (NFC・NFD) と大文字小文字を畳んで比べる", arguments: [
        "ガンマ 太字".precomposedStringWithCanonicalMapping,
        "ガンマ 太字".decomposedStringWithCanonicalMapping,
        "alpha bold", "ALPHA BOLD",
    ])
    func namesAreComparedWithoutSpellingDifferences(_ name: String) {
        #expect(Self.index().postScriptName(for: name) == "Alpha-Bold")
    }

    @Test("ファミリー名だけに当たるときは、列挙の先頭ではなく CoreText がそのファミリーで選ぶ面を引く")
    func aFamilyNameFindsTheFaceCoreTextChooses() {
        #expect(Self.index().postScriptName(for: "アルファ") == "Alpha-Regular")
        #expect(Self.index().postScriptName(for: "デルタ体") == "Delta-Medium")
    }

    @Test("CoreText の選ぶ面が当たった面の中に無ければ、列挙の先頭の面を引く")
    func aFamilyNameFallsBackToTheFirstFace() {
        #expect(Self.index(defaultFace: { _ in "Elsewhere" }).postScriptName(for: "アルファ") == "Alpha-Bold")
        #expect(Self.index(defaultFace: { _ in nil }).postScriptName(for: "アルファ") == "Alpha-Bold")
    }

    @Test("面そのものの名前は、同じ綴りのファミリー名より先に当たる")
    func aFaceNameBeatsAFamilyNameOfTheSameSpelling() {
        var faces = Self.faces()
        faces.append(
            .init(
                postScript: "Gamma-Regular", family: "Gamma", faceNames: ["Gamma-Regular", "アルファ"],
                familyNames: ["Gamma"]))
        let index = TypefaceNameIndex(faces: faces, defaultFace: { _ in "Alpha-Regular" })
        #expect(index.postScriptName(for: "アルファ") == "Gamma-Regular")
    }

    @Test("名前の無い面は引かない", arguments: ["", "NoSuchFont", "アルファ 斜体", "Alph"])
    func anUnknownNameFindsNothing(_ name: String) {
        #expect(Self.index().postScriptName(for: name) == nil)
    }

    // 複数の面に当たる面の名前 (#2563 の反証)。列挙は太さ順ではなく、同じ面が重複して並ぶ。
    private static func pingFangLike() -> [TypefaceNameIndex.Face] {
        func face(_ ps: String) -> TypefaceNameIndex.Face {
            .init(
                postScript: ps, family: "PingFang HK", faceNames: [ps, "苹方-港"],
                familyNames: ["PingFang HK", "苹方-港 体"])
        }
        // Semibold が先頭。UI 用と資産の 2 ファイルから、同じ面が重複して列挙される
        return [
            face("PingFangHK-Semibold"), face("PingFangHK-Regular"), face("PingFangHK-Semibold"),
            face("PingFangHK-Light"),
        ]
    }

    @Test("面の名前が複数の面に当たるときも、重複を畳み、CoreText がその名前で選ぶ面を引く")
    func aFaceNameOfSeveralFacesFindsTheFaceCoreTextChooses() {
        let index = TypefaceNameIndex(
            faces: Self.pingFangLike(),
            defaultFace: { $0 == "苹方-港" ? "PingFangHK-Regular" : nil })
        #expect(index.candidates(for: "苹方-港").map(\.postScript) == [
            "PingFangHK-Semibold", "PingFangHK-Regular", "PingFangHK-Light",
        ])
        #expect(index.postScriptName(for: "苹方-港") == "PingFangHK-Regular")
    }

    @Test("名前で選ばれる面が当たった面の中に無ければ、そのファミリー名で選ばれる面、それも無ければ列挙の先頭")
    func aFaceNameOfSeveralFacesFallsBack() {
        let byFamily = TypefaceNameIndex(
            faces: Self.pingFangLike(),
            defaultFace: { $0 == "PingFang HK" ? "PingFangHK-Light" : "Helvetica" })
        #expect(byFamily.postScriptName(for: "苹方-港") == "PingFangHK-Light")
        let none = TypefaceNameIndex(faces: Self.pingFangLike(), defaultFace: { _ in "Helvetica" })
        #expect(none.postScriptName(for: "苹方-港") == "PingFangHK-Semibold")
    }

    // MARK: - この環境の書体

    /// 名前の索引が断る名前のうち、書体の `name` 表にある別の言語の名前。**macOS に同梱の Verdana の
    /// 太字**で、スペイン語・ポルトガル語などの名前を持つ。前提 (索引が断る・書体が在る) は検査の頭で確かめる。
    nonisolated static let verdanaBoldNames = ["Verdana Negrita", "Verdana Negrito", "Verdana Fett", "Verdana Gras"]

    @Test("索引に載らない各言語の名前でも、書体の面を引く", arguments: verdanaBoldNames)
    func aNameMissingFromTheIndexResolvesToItsFace(_ name: String) throws {
        try #require(
            !Typeface.exists(name: name), "前提: この環境の CoreText の索引は \(name) を引けない")
        try #require(
            Typeface.exists(name: "Verdana-Bold"), "前提: この環境に Verdana-Bold がある")
        #expect(Typeface.resolvedName(of: name) == "Verdana-Bold")
    }

    @Test("索引が引ける名前と無い名前は、表を引かずに、いままでどおり")
    func theIndexedAndMissingNamesAreUnchanged() throws {
        #expect(Typeface.resolvedName(of: "Helvetica") == "Helvetica")
        #expect(Typeface.resolvedName(of: "helvetica") == "helvetica")
        #expect(Typeface.resolvedName(of: "NoSuchFont") == nil)
        #expect(Typeface.resolvedName(of: ".SFNS-Regular") == nil)
    }

    /// 在る名前が断られる件数 (この環境の全面 × 全言語の名前) を数え、0 を保つ。
    ///
    /// 名前は ``TypefaceNameIndex/systemFaces()`` が読んだもの (表示言語の名前・言語に依らない名前・
    /// 書体の `name` 表の全言語の名前) で、その名前すべてが `textFont` の入口 (`canonicalName` →
    /// `resolvedName`) を通ることを見る。
    @Test("この環境の全面の、読めるすべての名前が、断られない")
    func everyNameOfEveryFaceIsAccepted() throws {
        let faces = TypefaceNameIndex.systemFaces()
        try #require(
            faces.contains { $0.postScript == "Helvetica" }, "前提: 書体の一覧に Helvetica がある")
        var names = 0
        var indexRefused = 0
        var refused: [String] = []
        for face in faces {
            for name in face.faceNames + face.familyNames {
                names += 1
                let canonical = Typeface.canonicalName(name)
                if !Typeface.exists(name: canonical) { indexRefused += 1 }
                if Typeface.resolvedName(of: canonical) == nil {
                    refused.append("\(name) (\(face.postScript))")
                }
            }
        }
        try #require(
            names > 1000, "前提: この環境には 1000 以上の名前がある (\(names))")
        try #require(
            indexRefused > 0, "前提: CoreText の索引が引けない名前が在る (Verdana の各言語の名前)")
        #expect(refused.isEmpty, "断られた \(refused.count) 件 / \(names) 件: \(refused.prefix(10))")
    }

    /// 複数の面に当たる面の名前は、CoreText がその名前で選ぶ面に解ける (#2563 の反証)。**この環境の
    /// 全名前**で、表が当てた面の中に CoreText の選ぶ面 (名前で、無ければファミリー名で引いた面) があるのに別の面へ解けた件数を数え、0 を保つ。
    @Test("複数の面に当たる名前は、CoreText が選ぶ面が当たった面の中にあれば、その面に解ける")
    func everyAmbiguousNameResolvesToTheFaceCoreTextChooses() throws {
        let faces = TypefaceNameIndex.systemFaces()
        let index = TypefaceNameIndex.system
        var ambiguous = 0
        var wrong: [String] = []
        for name in Set(faces.flatMap { $0.faceNames + $0.familyNames }).sorted() {
            let canonical = Typeface.canonicalName(name)
            guard !Typeface.exists(name: canonical) else { continue }
            let candidates = index.candidates(for: canonical)
            guard candidates.count > 1 else { continue }
            ambiguous += 1
            // 名前で引いた面、無ければ (別の書体へ倒れたら) ファミリー名で引いた面
            let chosen = [canonical, candidates[0].family]
                .map { CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 12, nil)) as String }
                .first { name in candidates.contains { $0.postScript == name } }
            if let chosen,
                Typeface.resolvedName(of: canonical) != chosen
            {
                wrong.append("\(name): \(Typeface.resolvedName(of: canonical) ?? "nil") ≠ \(chosen)")
            }
        }
        try #require(ambiguous > 0, "前提: 索引が断る名前のうち、複数の面に当たる名前が在る")
        #expect(wrong.isEmpty, "\(wrong.count) 件: \(wrong.prefix(10))")
    }

    // MARK: - name 表の読み

    private struct Record {
        var platform: Int
        var encoding: Int
        var id: Int
        var bytes: [UInt8]
        /// 長さを偽る (nil なら実際の長さ)。
        var length: Int?
        /// 文字列の位置を偽る (nil なら本物)。
        var offset: Int?
    }

    private static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }

    /// `name` 表のバイト列を組む。`count` を偽れば、件数が表より大きい表を作れる。
    private static func table(_ records: [Record], count: Int? = nil) -> [UInt8] {
        var strings: [UInt8] = []
        var headers: [UInt8] = []
        for record in records {
            headers += u16(record.platform) + u16(record.encoding) + u16(0) + u16(record.id)
            headers += u16(record.length ?? record.bytes.count) + u16(record.offset ?? strings.count)
            strings += record.bytes
        }
        return u16(0) + u16(count ?? records.count) + u16(6 + records.count * 12) + headers + strings
    }

    private static func utf16(_ string: String) -> [UInt8] { Array(string.utf16).flatMap { u16(Int($0)) } }

    private static func macBytes(_ string: String, script: Int) -> [UInt8] {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(script)))
        return [UInt8](string.data(using: encoding) ?? Data())
    }

    private static func names(_ bytes: [UInt8]) -> [String] {
        TypefaceNameIndex.nameTableEntries(in: bytes).map(\.string)
    }

    @Test("name 表は、各台・各符号化の文字列を読み、名前でない ID は読まない")
    func theNameTableIsReadAcrossPlatformsAndEncodings() {
        let bytes = Self.table([
            .init(platform: 3, encoding: 1, id: 4, bytes: Self.utf16("ヒラギノ角ゴ W3")),
            .init(platform: 3, encoding: 0, id: 1, bytes: Self.utf16("Wingdings")),
            .init(platform: 3, encoding: 10, id: 16, bytes: Self.utf16("Family")),
            .init(platform: 0, encoding: 3, id: 4, bytes: Self.utf16("Unicode")),
            .init(platform: 1, encoding: 0, id: 1, bytes: Array("Roman é".data(using: .macOSRoman)!)),
            .init(platform: 1, encoding: 1, id: 4, bytes: Self.macBytes("ヒラギノ角ゴ", script: 1)),
            .init(platform: 1, encoding: 25, id: 4, bytes: Self.macBytes("苹方", script: 25)),
            .init(platform: 3, encoding: 1, id: 2, bytes: Self.utf16("Regular (サブファミリーは読まない)")),
        ])
        #expect(Self.names(bytes) == [
            "ヒラギノ角ゴ W3", "Wingdings", "Family", "Unicode", "Roman é", "ヒラギノ角ゴ", "苹方",
        ])
    }

    @Test("壊れた name 表でも落ちず、読めるところだけ読む")
    func aBrokenNameTableDoesNotCrash() {
        let good = Record(platform: 3, encoding: 1, id: 4, bytes: Self.utf16("Good"))
        // 空・ヘッダに満たない
        #expect(Self.names([]).isEmpty)
        #expect(Self.names([0, 0, 0, 1, 0]).isEmpty)
        // 件数が表より大きい: 読める分だけ読んで止まる
        #expect(Self.names(Self.table([good], count: 5000)) == ["Good"])
        // 文字列の位置が範囲外・長さが範囲外: その記録だけ飛ばす
        var far = good
        far.offset = 60000
        var long = good
        long.length = 60000
        #expect(Self.names(Self.table([far, good, long])) == ["Good"])
        // 奇数の長さの UTF-16 は読まない
        var odd = good
        odd.bytes = Self.utf16("Odd") + [0x41]
        #expect(Self.names(Self.table([odd, good])) == ["Good"])
        // 長さ 0・読み込みの無い符号化・Mac 台の範囲外の体系・旧来の Windows 符号化は飛ばす
        let skipped: [Record] = [
            .init(platform: 3, encoding: 1, id: 4, bytes: []),
            .init(platform: 3, encoding: 2, id: 4, bytes: [0x41, 0x42]),
            .init(platform: 1, encoding: 99, id: 4, bytes: [0x41]),
            .init(platform: 2, encoding: 0, id: 4, bytes: [0x41]),
        ]
        #expect(Self.names(Self.table(skipped + [good])) == ["Good"])
        // 文字列領域が表の外を指す
        var bytes = Self.table([good])
        bytes[4] = 0xff
        bytes[5] = 0xff
        #expect(Self.names(bytes).isEmpty)
        // 表が途中で切れている
        let whole = Self.table([good, good])
        for cut in 0..<whole.count { _ = TypefaceNameIndex.nameTableEntries(in: Array(whole.prefix(cut))) }
    }

    @Test("Windows のシンボル符号化 (3, 0) にしか名前が無い書体も、名前を引ける")
    func aSymbolEncodedNameTableIsRead() throws {
        // この環境の Wingdings・Webdings は (3, 0) にしか名前が無い (macOS 同梱)
        let font = CTFontCreateWithName("Wingdings" as CFString, 12, nil)
        try #require(
            (CTFontCopyPostScriptName(font) as String).hasPrefix("Wingdings"), "前提: この環境に Wingdings がある")
        #expect(TypefaceNameIndex.nameTableEntries(of: font).contains { $0.string.hasPrefix("Wingdings") })
    }

    /// 反証役が見つけた名前: 面の名前が複数の面に当たり、列挙の先頭 (Semibold など) へ解けていた。
    /// 前提は検査の頭で確かめる (この環境の CoreText が、その名前をどの面へ引くか)。
    @Test("複数の面に当たる名前は、先頭の面ではなく CoreText が選ぶ Regular に解ける", arguments: [
        ("苹方-港", "PingFangHK-Regular"), ("苹方-繁", "PingFangTC-Regular"),
        ("苹方-澳", "PingFangMO-Regular"),
    ])
    func aNameOfSeveralWeightsResolvesToRegular(_ name: String, _ postScript: String) throws {
        let canonical = Typeface.canonicalName(name)
        try #require(!Typeface.exists(name: canonical), "前提: この環境の索引は \(name) を引けない")
        let candidates = TypefaceNameIndex.system.candidates(for: canonical)
        try #require(candidates.count > 1, "前提: \(name) は複数の面に当たる")
        // 名前そのものは索引に無く別の書体 (Helvetica) へ倒れる。ファミリー名で引くと Regular が選ばれる
        let family = try #require(candidates.first?.family)
        try #require(
            CTFontCopyPostScriptName(CTFontCreateWithName(family as CFString, 12, nil)) as String
                == postScript,
            "前提: この環境の CoreText はファミリー名 \(family) を \(postScript) に引く")
        #expect(Typeface.resolvedName(of: canonical) == postScript)
    }
}
