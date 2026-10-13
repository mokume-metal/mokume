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
}
