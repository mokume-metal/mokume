// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 窓の × を押した人に確かめてから、スケッチを終える。
///
/// ## なぜ道具が起こしたときだけなのか
///
/// 窓は 3 通りの起こし方で建つ — 道具 (`mokume run`)・直に走らせる・束ねた `.app`。× は
/// そのどれでも唯一の出口で、押した瞬間に作品が終わる。制作中は押し間違いで走らせて
/// いるものが消えるが、**配った作品で終わり方に確認が挟まるのは道具の都合である**
/// ([ADR-0032] 決定 1 の「作品は道具に依存しない」)。
///
/// だから確かめるのは、道具が「確かめよ」と渡してきたときだけにする。合図が無ければ
/// 何も足さないので、直に走らせたスケッチと `.app` の経路は 1 行も変わらない。
///
/// ## 誰が言葉を決めるか
///
/// **押した後どうなるかは、起こし方で違う。** 見張り (`watch`) の窓は見張りごと終わり、
/// こちらは待っている道具まで終わる。合図の値が**渡した道具の名乗り**なのはそのためで、
/// 文面はそれを差し込んで組む — 名乗りを推し量ると、判定経路が二重になる
/// (`MOKUME_REPORT_RATE` が構成の名前を渡すのと同じ形)。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
enum CloseConfirmation {
    /// 確かめよと言ってきた道具の名乗り。**無ければ確かめない。**
    ///
    /// 綴りは一覧が持つ ([StartupReads])。空白だけの値は書かれていないものとして扱う。
    static func tool(environment: [String: String]) -> String? {
        guard let given = environment[StartupReads.closeConfirmation.key] else { return nil }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 起動の瞬間に決まる問い。**合図が無ければ持たない** (確かめずに閉じる)。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) が読み場所としてこのファイルを
    /// 名指ししている。
    static func startupQuestion(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloseQuestion? {
        guard let tool = tool(environment: environment) else { return nil }
        return question(tool: tool)
    }

    /// 問う言葉。
    ///
    /// **終わるのはスケッチと、待っている道具の両方である。** 端末に戻ってこない道具を
    /// 残したまま窓だけ畳むことはないので、押した人にはその両方を言う。
    static func question(tool: String) -> CloseQuestion {
        CloseQuestion(
            message: "Quit the sketch?",
            detail: "The sketch stops and its window closes. \(tool) ends with it.",
            confirm: "Quit",
            // **"Cancel" と言わない。** 押した人が取り消すのは「閉じる」ことであって、
            // 走っているものは続く
            cancel: "Keep running")
    }
}
