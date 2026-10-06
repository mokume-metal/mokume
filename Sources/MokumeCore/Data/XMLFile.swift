// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// XML の文字を要素の木へ読み解く。
///
/// ## 読み方
///
/// - 読み解くのは `XMLParser` で、その読み方に従う。文字は UTF-8 (呼ぶ側が
///   ``TextFile/text(of:path:)`` で解いてから渡す)。実体参照 (`&amp;` など) は解いた値で持つ
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

    /// XML の文字を読み解き、根の要素を返す。
    ///
    /// - Parameter path: 失敗を名乗るための名前。
    static func parse(_ text: String, path: String) throws(DataFailure) -> Element {
        let reader = Reader()
        let parser = XMLParser(data: Data(text.utf8))
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
