// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// XML の文字を要素の木へ読み解く。
///
/// ## 読み方
///
/// - 読み解くのは `XMLParser` で、その読み方に従う。文字は UTF-8 (呼ぶ側が
///   ``TextFile/text(of:path:)`` で解いてから渡す)。実体参照 (`&amp;` など) は解いた値で持つ
/// - **XML 宣言の `encoding` は読まない。** 文字は UTF-8 と決まっているので、宣言が
///   `Shift_JIS` と名乗っていても UTF-8 として読む。**行の終わりは LF・CRLF・CR のどれでもよく**、
///   名乗る行は ``TextFile/lines(of:)`` と同じ数え方になる (どちらも ``document(of:)``)
/// - **外の実体 (`SYSTEM`) は読まない** (`XMLParser` の既定)。XML の中の名前から手元の
///   ファイルや外の URL を読みに行かない
/// - 持つのは要素の名前・属性・子の要素。名前空間の前置きは名前の一部として扱う (`s:b`)
/// - **入れ子は、根の下に 512 段まで** (``deepest``)。JSON (``JSONFile``) の上限と揃えた
///
/// ## なぜ入れ子に上限を置くのか
///
/// `XMLParser` は 10 万段の入れ子でも読み通す。ところが、作った木を比べる・手放す仕事は段ごとに
/// 呼び出しを重ねるので、深さに比例してスタックを使う。10 万段の木は main thread と同じ 8 MB の
/// スタックでも尽きて、プロセスごと落ちる (手元で確かめた・#2070)。読んだ後に落ちるより、読む
/// ときに投げる。
///
/// ## 壊れた XML は投げる
///
/// 閉じない要素・閉じる名前の食い違い・不正な文字・要素の無い文字・根が 2 つ・深すぎる入れ子は
/// ``DataFailure/malformed(path:line:reason:)`` で、壊れていた行を添えて投げる。理由の 1 文は
/// `XMLParser` (libxml2) の文面を使い、文字の終わりで起きた壊れ方だけを自分の言葉で言い直す
/// (``endReason(_:)``)。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読み解きを別の仕事として回すため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum XMLFile {
    /// 要素 1 つ。``XML`` にする前の形。
    struct Element: Equatable, Sendable {
        var name: String
        var attributes: [String: String]
        var children: [Element]
    }

    /// 読める入れ子の深さ。根の要素を 1 段と数え、その下に 512 段 (`JSONSerialization` が読める
    /// 深さと同じ数え方)。
    static let deepest = 513

    /// `XMLParser` に渡すバイトを作る。**文字を UTF-8 のバイトにして、そのままは渡さない。**
    /// 次の 2 つを整える。`XMLParser` を作る所 (``parse(_:path:)`` と ``SVGFile/parse(_:path:)``)
    /// はどちらもここを通すので、XML も SVG も同じ読み方になる。
    ///
    /// - **行の終わりを LF に揃える。** CRLF と単独の CR を LF に置き換える。XML 1.0 (2.11) が
    ///   読み手に求めている正規化である。libxml2 は LF だけを行と数えるので、揃えないと CR だけで
    ///   改行した文書は丸ごと 1 行になり、壊れた行も要素の行も 1 になる
    ///   (``TextFile/lines(of:)`` は CR も行の終わりと数える)。文字参照で書いた CR (`&#13;`) は
    ///   参照のままで、揃えない。CDATA の中の CR は、libxml2 だけなら LF に揃わずに届くが、
    ///   XML 1.0 のとおり揃う
    /// - **XML 宣言の `encoding` を `UTF-8` にする。** 文字は呼ぶ側が UTF-8 と決めて解いて
    ///   渡すので、宣言が `Shift_JIS` や `ISO-8859-1` と名乗っていても、渡すバイトは UTF-8 である。
    ///   libxml2 は宣言に従ってバイトを解き直すので、そのままだと UTF-8 として読めた文書が
    ///   ``DataFailure/malformed(path:line:reason:)`` で投げられたり、投げずに文字化けした値になったりする。
    ///   書き換えるのは文書の先頭の XML 宣言の値だけで、行は動かない。宣言の外の
    ///   `encoding="…"` (コメント・属性の値・`<?xml-stylesheet …?>`) には触れない
    static func document(of text: String) -> Data {
        var bytes = Array(text.utf8)
        // CR は UTF-8 の多バイトの文字の中には現れないので、バイトで見てよい
        if bytes.contains(0x0D) { bytes = unifyingLineBreaks(bytes) }
        declareUTF8(&bytes)
        return Data(bytes)
    }

    /// CRLF と単独の CR を LF にする。
    private static func unifyingLineBreaks(_ bytes: [UInt8]) -> [UInt8] {
        var unified: [UInt8] = []
        unified.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x0D {
                unified.append(0x0A)
                if index < bytes.count, bytes[index] == 0x0A { index += 1 }
            } else {
                unified.append(byte)
            }
        }
        return unified
    }

    /// 文書の先頭の XML 宣言 (`<?xml version="1.0" encoding="…"?>`) に `encoding` があれば、
    /// その値を `UTF-8` にする。宣言が無い・`encoding` が無い・読めない形なら、何もしない
    /// (壊れ方は libxml2 が言う)。
    private static func declareUTF8(_ bytes: inout [UInt8]) {
        let opening = Array("<?xml".utf8)
        guard bytes.starts(with: opening), bytes.count > opening.count, isSpace(bytes[opening.count])
        else { return }
        var index = opening.count
        // 宣言の中は `名前 = "値"` の並び。= の前後に空白があってよく、引用符は 2 種類
        while true {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            let nameStart = index
            while index < bytes.count, isLetter(bytes[index]) { index += 1 }
            let name = bytes[nameStart..<index]
            guard !name.isEmpty else { return }  // `?>` に着いたか、読めない形
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return }
            index += 1
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'")
            else { return }
            let quote = bytes[index]
            let valueStart = index + 1
            guard let valueEnd = bytes[valueStart...].firstIndex(of: quote) else { return }
            if name.elementsEqual("encoding".utf8) {
                let value = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
                // 既に UTF-8 なら、バイトを作り直さない
                if value.lowercased() != "utf-8" { bytes.replaceSubrange(valueStart..<valueEnd, with: "UTF-8".utf8) }
                return
            }
            index = valueEnd + 1
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// XML の文字を読み解き、根の要素を返す。
    ///
    /// - Parameter path: 失敗を名乗るための名前。
    static func parse(_ text: String, path: String) throws(DataFailure) -> Element {
        let reader = Reader()
        let parser = XMLParser(data: document(of: text))
        parser.delegate = reader
        // 既定のままだが、約束なので名指しで置く。XML の中の名前 (`SYSTEM "file:///…"`) から
        // 手元のファイルや外の URL を読みに行かない
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        // 戻り値は見ない。成否は読み手の控え (根ができたか・壊れていたか) で決める
        _ = parser.parse()
        // 行は文字の行の数を越えない。最後の改行の後ろ (行を作らない — ``TextFile/lines(of:)``)
        // で起きた壊れ方は、最後の行のものとして名乗る
        let last = max(1, TextFile.lines(of: text).count)
        if let failure = reader.failure {
            let reason =
                failure.code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue
                ? endReason(reader) : failure.reason
            throw .malformed(path: path, line: min(max(1, failure.line), last), reason: reason)
        }
        if let root = reader.root { return root }
        // `XMLParser` が理由を言わずに止まるのは、文字の終わりで起きた壊れ方 (手元で確かめた)
        throw .malformed(path: path, line: last, reason: endReason(reader))
    }

    /// 文字の終わりで起きた壊れ方を、読み手の控えから言う。
    ///
    /// **libxml2 の文面は、ここでは役に立たない。** 根を閉じ忘れても、空白しか無くても、根が
    /// 2 つあっても、同じ `Extra content at the end of the document` (番号 5) と言うか、何も
    /// 言わずに止まる。どれなのかは、開いたままの要素と閉じ終えた根から分かる。
    private static func endReason(_ reader: Reader) -> String {
        if let open = reader.open.last {
            return "the text ended before <\(open.name)> was closed"
        }
        if let root = reader.root {
            return "there is more after the root element <\(root.name)>. "
                + "An XML document has exactly one root element"
        }
        return "there is no element in it"
    }

    /// `XMLParser` から届く知らせを、要素の木に組む。
    ///
    /// **組むのは積み上げで、呼び出しを重ねない。** 開いた要素を ``open`` に積み、閉じたら
    /// 下ろして親の子に足す。
    private nonisolated final class Reader: NSObject, XMLParserDelegate {
        /// 開いていて、まだ閉じていない要素。末尾が最も内側。
        var open: [Element] = []
        /// 閉じ終えた根の要素。
        var root: Element?
        /// 最初に見つけた壊れ方。2 つ目からは控えない (最初の 1 つが原因で、後は巻き添え)。
        var failure: (line: Int, code: Int, reason: String)?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            guard open.count < XMLFile.deepest else {
                failure =
                    failure
                    ?? (
                        parser.lineNumber, 0,
                        "elements are nested deeper than \(XMLFile.deepest - 1) levels below the root"
                    )
                parser.abortParsing()
                return
            }
            open.append(Element(name: elementName, attributes: attributeDict, children: []))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard let closed = open.popLast() else { return }
            if open.isEmpty {
                root = closed
            } else {
                open[open.count - 1].children.append(closed)
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            guard failure == nil else { return }
            let error = parseError as NSError
            // 文面は、知らせに添えられた libxml2 の 1 文 (`Opening and ending tag mismatch: …`)。
            // 読み終えた後の `parser.parserError` は、どの壊れ方でも同じ番号 (111) になって
            // いて理由を持たないので、ここで控える
            let line = error.userInfo["NSXMLParserErrorLineNumber"] as? Int ?? parser.lineNumber
            let message =
                (error.userInfo["NSXMLParserErrorMessage"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            failure = (line, error.code, message.isEmpty ? "the XML could not be read" : message)
        }
    }
}
