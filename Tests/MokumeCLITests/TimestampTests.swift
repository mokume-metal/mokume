// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 日時の綴りが、**読む人の設定に依らない**か。
///
/// `DateFormatter` は `locale` を与えなければ `Locale.current` に従うので、和暦にしている
/// 機械では `yyyy` が令和年を出す。切り分けの口 (`doctor`) がそれを踏んでいた
/// ([#986](https://github.com/mokume-metal/mokume/issues/986))。
///
/// **利用者の設定そのものは検査から差し替えられない**ので、ここは 2 つに分けて確かめる —
/// 「渡された言い方に従うこと」と「渡されなかったときの既定が固定の言い方であること」。
/// 2 つ揃えば、暦設定が何であろうと出力が動かないと言える。
@Suite("日時の綴り")
struct TimestampTests {
    /// 2025-08-24 (JST では 10:46:40)。**西暦と令和年で数字が全く違う**日付なら何でもよい。
    private let date = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("和暦の言い方を渡せば、年は令和年になる")
    func aJapaneseCalendarChangesTheYear() {
        let japanese = Timestamp.text(date, locale: Locale(identifier: "ja_JP@calendar=japanese"))
        // 令和 7 年。**危うさが実在することをここが示す** — 渡した言い方に従うのだから、
        // 既定を固定しなければ利用者の設定がそのまま出る
        #expect(japanese.hasPrefix("0007-"))
        #expect(!japanese.hasPrefix("2025-"))
    }

    @Test("既定の言い方は、利用者の設定ではなく en_US_POSIX")
    func defaultsToAFixedLocale() {
        #expect(Timestamp.locale.identifier == "en_US_POSIX")
    }

    @Test("既定では西暦で出す")
    func staysGregorianByDefault() {
        #expect(Timestamp.text(date).hasPrefix("2025-"))
        #expect(Timestamp.text(date, seconds: true).hasPrefix("2025-"))
    }

    @Test("秒を出すかは呼び手が選ぶ")
    func secondsAreTheCallersChoice() {
        // 書式そのものは固定しない (読みやすさを直すたびに検査が落ちる) が、**秒の有無は
        // 呼び手の指定なので、切り替わることは見る**
        let minutes = Timestamp.text(date)
        let withSeconds = Timestamp.text(date, seconds: true)
        #expect(withSeconds.hasPrefix(minutes))
        #expect(withSeconds.count == minutes.count + 3)
    }
}
