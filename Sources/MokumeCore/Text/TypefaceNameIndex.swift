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
/// - **面そのものの名前** (フルネーム・PostScript 名) に当たれば、その面。ファミリー名だけに当たれば、
///   そのファミリーの面
/// - **複数の面に当たるときは、CoreText が選ぶ面に揃える** — その名前、次にそのファミリー名を
///   `CTFontCreateWithName` に渡して選ばれる面が、当たった面の中にあればそれ。無ければ列挙の先頭
///   (列挙は太さ順ではないので、先頭を無条件には返さない)
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
    /// 名前 (面の名前・ファミリー名) を CoreText に渡したときに選ばれる面の PostScript 名。
    private let defaultFace: (String) -> String?

    /// 材料から表を作る。`defaultFace` は、名前 (面の名前かファミリー名) で CoreText が選ぶ面の PostScript 名。
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

    /// 名前が当たる面 (PostScript 名の重複は 1 つにする)。面そのものの名前に当たればその面たち、
    /// ファミリー名だけに当たれば最初に当たったファミリーの面たち。列挙の順。
    ///
    /// **同じ面が複数のファイルから重複して列挙される** (`PingFangUI.ttc` と資産の `PingFang.ttc`)
    /// ので、PostScript 名で畳む。
    func candidates(for name: String) -> [Face] {
        guard let found = hits[Self.key(of: name)] else { return [] }
        var chosen = found.filter { !$0.viaFamily }
        if chosen.isEmpty, let first = found.first {
            let family = faces[first.face].family
            chosen = found.filter { faces[$0.face].family == family }
        }
        var seen = Set<String>()
        return chosen.map { faces[$0.face] }.filter { seen.insert($0.postScript).inserted }
    }

    /// 名前が指す面の PostScript 名。無ければ `nil`。
    ///
    /// **名前が複数の面に当たるときは、CoreText が選ぶ面に揃える** (面の名前でもファミリー名でも)。
    /// 名前そのもので引いた面、次にその面のファミリー名で引いた面のうち、当たった面の中にある
    /// ものを使う。どちらも当たった面の中に無いときだけ、列挙の先頭。列挙は太さ順ではない。
    func postScriptName(for name: String) -> String? {
        let list = candidates(for: name)
        guard let first = list.first else { return nil }
        guard list.count > 1 else { return first.postScript }
        for query in [name, first.family] {
            if let chosen = defaultFace(query), list.contains(where: { $0.postScript == chosen }) {
                return chosen
            }
        }
        return first.postScript
    }

    /// この環境の書体から作った表。**初回に 1 度だけ作る** — 名前の索引が断った名前が来たときだけ
    /// 触れるので、名前が正しいスケッチは作らない。作るのは全面の列挙と名前の読み出しで、毎フレーム
    /// `textFont` が呼ばれても、列挙を繰り返さない。
    static let system = TypefaceNameIndex(
        faces: systemFaces(),
        defaultFace: { name in
            CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String
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
    /// すべての言語ぶん読む。表の取り出しだけの薄い入れ物で、読み方は ``nameTableEntries(in:)``。
    static func nameTableEntries(of font: CTFont) -> [(id: Int, string: String)] {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data?
        else { return [] }
        return nameTableEntries(in: [UInt8](table))
    }

    /// `name` 表のバイト列から、名前 (ID 1・4・16) をすべての言語ぶん読む。**壊れた表でも落ちない** —
    /// 範囲外の記録・文字列は飛ばし、件数が表より大きければ読めるところまでで止める。
    ///
    /// 文字列の読み方は台と符号化で決まる。
    /// - Unicode 台 (0)・Windows 台 (3) の符号化 0 (シンボル)・1・10: UTF-16BE。奇数の長さは壊れていて読まない
    /// - Mac 台 (1): 符号化は Mac の文字体系の番号で、CoreFoundation の同じ番号の符号化で読む
    ///   (Roman・日本語・繁体中文・韓国語・簡体中文など)。読み込みが無い符号化・不正な並びは飛ばす
    /// - Windows 台の旧来の符号化 (2 Shift_JIS・3 PRC・4 Big5 など) は読まない。同じ名前は Unicode の
    ///   符号化 (1) にもあるのが普通で、読まずに失う名前は確かめていない
    static func nameTableEntries(in bytes: [UInt8]) -> [(id: Int, string: String)] {
        func u16(_ offset: Int) -> Int? {
            offset >= 0 && offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : nil
        }
        guard let count = u16(2), let stringBase = u16(4) else { return [] }
        var entries: [(id: Int, string: String)] = []
        for index in 0..<count {
            let record = 6 + index * 12
            guard record + 12 <= bytes.count else { break }
            guard let platform = u16(record), let encoding = u16(record + 2), let id = u16(record + 6),
                let length = u16(record + 8), let offset = u16(record + 10),
                [1, 4, 16].contains(id)
            else { continue }
            let start = stringBase + offset
            guard length > 0, start + length <= bytes.count else { continue }
            let data = Data(bytes[start..<start + length])
            let string: String?
            switch (platform, encoding) {
            case (0, _), (3, 0), (3, 1), (3, 10):
                string = length.isMultiple(of: 2) ? String(data: data, encoding: .utf16BigEndian) : nil
            case (1, _) where encoding <= 32:
                let encoding = CFStringEncoding(encoding)
                string =
                    CFStringIsEncodingAvailable(encoding)
                    ? CFStringCreateWithBytes(nil, [UInt8](data), data.count, encoding, false) as String?
                    : nil
            default: string = nil
            }
            if let string, !string.isEmpty { entries.append((id, string)) }
        }
        return entries
    }
}
