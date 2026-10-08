// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeNetwork

/// 届いたバイト列を文字列に読む決まり (#2018)。通信はしない。
@Suite("文字列の読み方")
struct TextDecodingTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func lines(_ cut: (lines: [[UInt8]], overlong: Int)) -> [String] {
        cut.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - 1 つのメッセージ (UDP・WebSocket)

    @Test("末尾の改行 1 つ (\\n か \\r\\n) だけを落とし、ほかは触らない")
    func messageDropsOneTrailingNewline() {
        #expect(TextDecoding.message(bytes("0.3\n")) == "0.3")
        #expect(TextDecoding.message(bytes("0.3\r\n")) == "0.3")
        #expect(TextDecoding.message(bytes("0.3\n\n")) == "0.3\n")
        #expect(TextDecoding.message(bytes("a\nb")) == "a\nb")
        #expect(TextDecoding.message(bytes("0.3\r")) == "0.3\r")  // \r だけは改行と見ない
        #expect(TextDecoding.message(bytes(" 0.3 ")) == " 0.3 ")
        #expect(TextDecoding.message(bytes("\n")) == "")
        #expect(TextDecoding.message([]) == "")
        #expect(TextDecoding.message(bytes("円 ⏎\n")) == "円 ⏎")
    }

    @Test("UTF-8 として読めないものは読まない")
    func invalidUTF8IsUnreadable() {
        #expect(TextDecoding.message([0xFF]) == nil)
        #expect(TextDecoding.message([0x61, 0xE3, 0x81]) == nil)  // 途中で切れた文字
        #expect(TextDecoding.datagram([0xFF]).unreadable == 1)
        #expect(TextDecoding.datagram([0xFF]).messages.isEmpty)
        #expect(TextDecoding.datagram(bytes("ok\n")).messages == ["ok"])
        #expect(TextDecoding.datagram(bytes("ok\n")).unreadable == 0)
    }

    // MARK: - 行 (TCP)

    @Test("改行で行に切り、行の終わりの \\r を落とす。空の行も 1 行")
    func splitsLines() {
        var splitter = LineSplitter(limit: 100)
        #expect(lines(splitter.append(bytes("0.25\nhit\r\n\nlast"))) == ["0.25", "hit", ""])
        #expect(splitter.finish().map { String(decoding: $0, as: UTF8.self) } == "last")
        #expect(splitter.finish() == nil)
    }

    @Test("行の途中で切れて届いても、次に届いた分とつないで 1 行にする")
    func joinsAcrossChunks() {
        var splitter = LineSplitter(limit: 100)
        #expect(lines(splitter.append(bytes("0."))).isEmpty)
        #expect(lines(splitter.append(bytes("7"))).isEmpty)
        #expect(lines(splitter.append(bytes("5\r"))).isEmpty)
        #expect(lines(splitter.append(bytes("\nnext\n"))) == ["0.75", "next"])
        #expect(splitter.finish() == nil)
    }

    @Test("上限を超えた行は捨てて数え、次の改行まで読み飛ばす。上限ちょうどは通る")
    func overlongLinesAreDropped() {
        var splitter = LineSplitter(limit: 4)
        let cut = splitter.append(bytes("abcd\nabcdefgh"))
        #expect(lines(cut) == ["abcd"])
        #expect(cut.overlong == 1)
        // 続きが届いても、前の行の後半を別の行にしない
        let rest = splitter.append(bytes("ijk\nok\n"))
        #expect(lines(rest) == ["ok"])
        #expect(rest.overlong == 0)
        // 閉じたときに読み飛ばしている途中なら、残りは渡さない
        _ = splitter.append(bytes("toolong"))
        #expect(splitter.finish() == nil)
        #expect(lines(splitter.append(bytes("fine\n"))) == ["fine"])
    }
}
