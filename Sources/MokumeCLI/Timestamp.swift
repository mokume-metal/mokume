// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 日時を、**読む人の設定に依らない綴りで**書く。
///
/// ## なぜ言い方を固定するのか
///
/// `DateFormatter` は `locale` を与えなければ `Locale.current` に従う — **「未指定」という
/// 状態は無い。** 和暦にしている機械では `yyyy` が令和年を出すので、`doctor` の出力が
/// `0008-09-06 15:04:32` になる ([#986])。**日付として読めてしまう**ぶん質が悪く、落ちも
/// 警告も出ないので、打った本人には壊れて見えない。混乱するのは貼られたログを読む側である。
///
/// 暦だけではない。月名も数字の字形も設定次第で変わる。`en_US_POSIX` はまさにこれを
/// 避けるための言い方で、Apple の Technical Q&A QA1480 が「書式を固定した日時には必ず
/// 使え」と書いている。
///
/// ## なぜ 1 本にするのか
///
/// 同じことを ``ToolVersion`` と ``DoctorCommand`` が別々に書いていて、**片方にしか指定が
/// 無かった。** 割れても何も言わないうえ、同じ `doctor` の出力の中で `道具:` の行が西暦・
/// `最後の作り直し:` の行が令和年という形で並ぶ — [ADR-0008] 決定 6 が言う「黙って壊れる」
/// 側である。2 本の違いは秒を出すかどうか 1 つだけなので、引数 1 個で引き受けられる。
///
/// [#986]: https://github.com/mokume-metal/mokume/issues/986
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
enum Timestamp {
    /// 日時に使う言い方。**利用者の設定ではなく、これを使う。**
    static let locale = Locale(identifier: "en_US_POSIX")

    /// 日時の綴り。
    ///
    /// - Parameter seconds: 秒まで出すか。**既定は分まで** — 道具の版の名乗りでは、秒は
    ///   読み手の判断を変えない。秒を要るのは `doctor` の「最後の作り直し」だけで、
    ///   あちらは `watch` が何度も書き直すので、どの回のことかを分では分けられない。
    /// - Parameter locale: **検査から割れを作るための口。** 既定を変えて呼ばない
    ///   (``DoctorCommand/text(for:workDirectory:)`` と同じ流儀)。
    static func text(_ date: Date, seconds: Bool = false, locale: Locale = Timestamp.locale)
        -> String
    {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
