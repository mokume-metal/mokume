// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ASCII の字で性質表を引かない空白・改行の判定が、元の判定と同じ答えを返すことの検査
/// ([#1784])。GPU を要さない。
///
/// 近道は ASCII の字にだけ効くので、**ASCII の全 128 字**と、`asciiValue` が取れるのに
/// 1 字ではない `"\r\n"`、ASCII に結合文字が付いて `asciiValue` が取れなくなる字、
/// 近道を通らない ASCII の外の空白・改行を比べる。
///
/// [#1784]: https://github.com/mokume-metal/mokume/issues/1784
@Suite("ASCII の近道つきの空白と改行")
struct CharacterQuickClassTests {
    /// 比べる字。
    private static let characters: [Character] = {
        var all: [Character] = []
        for code in UInt8(0)...UInt8(127) {
            let ascii = Character(Unicode.Scalar(code))
            all.append(ascii)
            // 結合文字が付くと 1 字のまま asciiValue が nil になる。制御文字には付かず
            // 2 字に割れるので、1 字にまとまるものだけを比べる
            let combined = String(ascii) + "\u{0301}"
            if combined.count == 1 { all.append(Character(combined)) }
        }
        all.append("\r\n")
        // ASCII の外の空白・改行と、改行しない空白・ふつうの字
        let others: [Unicode.Scalar] = [
            "\u{0085}", "\u{00A0}", "\u{1680}", "\u{2007}", "\u{2028}", "\u{2029}", "\u{202F}",
            "\u{3000}", "あ", "é",
        ]
        for scalar in others { all.append(Character(scalar)) }
        return all
    }()

    @Test("改行の判定が、元の isNewline と同じ答えを返す")
    func newlineMatchesTheOriginal() {
        for character in Self.characters {
            #expect(
                character.isNewlineQuickly == character.isNewline,
                "\(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test("空白の判定が、元の isWhitespace と同じ答えを返す")
    func whitespaceMatchesTheOriginal() {
        for character in Self.characters {
            #expect(
                character.isWhitespaceQuickly == character.isWhitespace,
                "\(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    /// 流し込みの「折ってよい空白」も、近道を足す前の式と同じ答えを返す。
    @Test("折ってよい空白の判定が、近道を足す前の式と同じ答えを返す")
    func breakingSpaceMatchesTheOriginal() {
        let noBreak: Set<Unicode.Scalar> = ["\u{00A0}", "\u{202F}", "\u{2007}"]
        for character in Self.characters {
            let original =
                character.isWhitespace && !character.unicodeScalars.contains { noBreak.contains($0) }
            #expect(
                character.isBreakingSpace == original,
                "\(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
