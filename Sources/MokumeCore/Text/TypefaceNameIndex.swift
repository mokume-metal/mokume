// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// 書体メニューや Font Book に出る各言語の名前から、面を引く表 ([#2563])。
///
/// CoreText の名前の索引 (`CTFontCreateWithName` と記述子での照合) には、**書体メニューに出る名前の
/// うち載らないものがある** — 日本語表示の `ヒラギノ角ゴ 簡体中文 W3`・`黒体-簡 ミディアム`、後から入れた
/// 書体の表示名など。``Typeface/exists(name:)`` が断った名前を、この表で引き直す。
///
/// ## 引き方
///
/// - 名前は NFC に直し、大文字小文字を畳んで比べる (``key(of:)``)。
/// - **面そのものの名前** (フルネーム・PostScript 名) に当たれば、その面。複数なら列挙の順で先頭
/// - **ファミリー名だけに当たれば**、CoreText がそのファミリー名で選ぶ面。PostScript 名・ファミリー名で
///   引いたときと同じ「CoreText が選ぶ 1 面」に揃える
///
/// 表が返すのは PostScript 名で、呼ぶ側 (``Typeface/resolvedName(of:)``) が CoreText で引き直して
/// 同じ面に戻ることを確かめる。
///
/// [#2563]: https://github.com/mokume-metal/mokume/issues/2563
struct TypefaceNameIndex {
    /// 1 つの面の名前。表を作る材料で、CoreText に依らず渡せる (検査が合成の材料で作れる)。
    struct Face: Equatable {
        /// 面の PostScript 名。表が返すのはこれ。
        var postScript: String
        /// 面を選ぶときのファミリー名 (言語に依らない綴り)。
        var family: String
        /// この面そのものの名前 (フルネーム・PostScript 名・各言語のフルネーム)。
        var faceNames: [String]
        /// この面が属するファミリーの名前 (各言語の)。
        var familyNames: [String]
    }

    private struct Hit {
        var face: Int
        var viaFamily: Bool
    }

    private let faces: [Face]
    private let hits: [String: [Hit]]
    /// ファミリー名を CoreText に渡したときに選ばれる面の PostScript 名。
    private let defaultFace: (String) -> String?

    /// 材料から表を作る。`defaultFace` は、ファミリー名で CoreText が選ぶ面の PostScript 名。
    init(faces: [Face], defaultFace: @escaping (String) -> String?) {
        self.faces = faces
        self.defaultFace = defaultFace
        var hits: [String: [Hit]] = [:]
        for (index, face) in faces.enumerated() {
            for name in face.faceNames {
                hits[Self.key(of: name), default: []].append(Hit(face: index, viaFamily: false))
            }
            for name in face.familyNames {
                hits[Self.key(of: name), default: []].append(Hit(face: index, viaFamily: true))
            }
        }
        self.hits = hits
    }

    /// 名前を比べる綴り。濁点を合わせ (NFC)、大文字小文字を畳む。
    static func key(of name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// 名前が指す面の PostScript 名。無ければ `nil`。
    func postScriptName(for name: String) -> String? {
        guard let found = hits[Self.key(of: name)] else { return nil }
        let faceHits = found.filter { !$0.viaFamily }
        if let first = faceHits.first { return faces[first.face].postScript }
        // ファミリー名だけに当たった。複数の面が当たるので、CoreText がそのファミリーで選ぶ面を使う
        guard let first = found.first else { return nil }
        let family = faces[first.face].family
        let sameFamily = found.filter { faces[$0.face].family == family }
        if let chosen = defaultFace(family),
            sameFamily.contains(where: { faces[$0.face].postScript == chosen })
        {
            return chosen
        }
        return faces[first.face].postScript
    }

    /// この環境の書体から作った表。**初回に 1 度だけ作る** — 名前の索引が断った名前が来たときだけ
    /// 触れるので、名前が正しいスケッチは作らない。作るのは全面の列挙と名前の読み出しで、毎フレーム
    /// `textFont` が呼ばれても、列挙を繰り返さない。
    static let system = TypefaceNameIndex(
        faces: systemFaces(),
        defaultFace: { family in
            CTFontCopyPostScriptName(CTFontCreateWithName(family as CFString, 12, nil)) as String
        })

    /// この環境の全面と、その名前。システムの内部名 (`.` で始まる) は除く。
    static func systemFaces() -> [Face] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors =
            CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var faces: [Face] = []
        faces.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            guard
                let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
                    as? String,
                !postScript.hasPrefix(".")
            else { continue }
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            faces.append(names(of: font, postScript: postScript))
        }
        return faces
    }

    /// 1 つの面の名前を、読めるだけ集める。
    ///
    /// - 表示言語の名前 (`CTFontCopyLocalizedName`)。**CoreText が持つ翻訳**で、書体の中には無い
    ///   (`黒体-簡 ミディアム`) ので、これでしか拾えない名前がある
    /// - 言語に依らない名前 (`CTFontCopyName`)
    /// - 書体の `name` 表にある**全言語**の名前。表示言語が違う環境で書かれた名前も引ける
    static func names(of font: CTFont, postScript: String) -> Face {
        var faceNames = [postScript]
        var familyNames: [String] = []
        if let name = CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String? {
            faceNames.append(name)
        }
        if let name = CTFontCopyName(font, kCTFontFullNameKey) as String? { faceNames.append(name) }
        if let name = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String? {
            familyNames.append(name)
        }
        if let name = CTFontCopyName(font, kCTFontFamilyNameKey) as String? {
            familyNames.append(name)
        }
        for entry in nameTableEntries(of: font) {
            switch entry.id {
            case 4: faceNames.append(entry.string)
            case 1, 16: familyNames.append(entry.string)
            default: break
            }
        }
        return Face(
            postScript: postScript,
            family: CTFontCopyFamilyName(font) as String,
            faceNames: faceNames.filter { !$0.isEmpty && !$0.hasPrefix(".") },
            familyNames: familyNames.filter { !$0.isEmpty && !$0.hasPrefix(".") })
    }

    /// 書体の `name` 表のうち、名前 (1 ファミリー・4 フルネーム・16 タイポグラフィのファミリー) を
    /// すべての言語ぶん読む。**文字列を読めない符号化は飛ばす** (Mac 台は Roman だけ。同じ名前は
    /// 大抵 Windows 台にもある)。
    static func nameTableEntries(of font: CTFont) -> [(id: Int, string: String)] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data?
        else { return [] }
        let bytes = [UInt8](table)
        func u16(_ offset: Int) -> Int {
            offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : 0
        }
        guard bytes.count >= 6 else { return [] }
        let count = u16(2)
        let stringBase = u16(4)
        var entries: [(id: Int, string: String)] = []
        for index in 0..<count {
            let record = 6 + index * 12
            guard record + 12 <= bytes.count else { break }
            let (platform, encoding, id) = (u16(record), u16(record + 2), u16(record + 6))
            guard [1, 4, 16].contains(id) else { continue }
            let (length, offset) = (u16(record + 8), stringBase + u16(record + 10))
            guard offset + length <= bytes.count else { continue }
            let data = Data(bytes[offset..<offset + length])
            let string: String?
            switch (platform, encoding) {
            case (0, _), (3, 1), (3, 10): string = String(data: data, encoding: .utf16BigEndian)
            case (1, 0): string = String(data: data, encoding: .macOSRoman)
            default: string = nil
            }
            if let string, !string.isEmpty { entries.append((id, string)) }
        }
        return entries
    }
}
