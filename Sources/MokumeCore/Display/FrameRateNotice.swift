// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 走っている速さを名乗る。
///
/// ## なぜ構成を同じ行に置くのか
///
/// **速さは構成で数倍変わる。** 数字だけを見せると「重い / 軽い」の判断が構成の違いに
/// 引きずられ、最適化していない側の数字を見て作品を作り直す、という手戻りが起きる。
/// 別の場所に書いてあっても読まれないので、**同じ行に置く** ([ADR-0029] 決定 3)。
///
/// ## なぜスケッチが判定しないのか
///
/// 速さを知っているのは走っているプロセスで、**構成を知っているのは道具**である。同じ行に
/// 載せるには一方が他方へ渡すしかない。道具が「一緒に出す名前」を環境変数で渡し、ここは
/// 渡された文字列を添えるだけにする — スケッチの側で構成を推し量ると、判定経路が二重に
/// なる。`MOKUME_SOURCE_STAMP` (道具が渡し、観測が応答へそのまま載せる) と同じ形である。
///
/// ## 名乗らない既定
///
/// 鍵が与えられなければ**何も出さない**。窓口から立てたスケッチの出力が 1 バイトも
/// 変わらないことが、この既定で保たれる ([ADR-0029] 決定 5 の 2 番目)。
///
/// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
public enum FrameRateNotice {
    /// 一緒に出す構成の名前。**無ければ名乗らない。**
    ///
    /// 綴りは一覧が持つ ([StartupReads])。空白だけの値は書かれていないものとして扱う。
    public static func configuration(environment: [String: String]) -> String? {
        guard let given = environment[StartupReads.frameRateNotice.key] else { return nil }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// このプロセスに与えられた名乗り。**環境を読むのはここだけ** — 一覧
    /// ([StartupReads]) が読み場所としてこのファイルを名指ししている。
    public static var configuration: String? {
        configuration(environment: ProcessInfo.processInfo.environment)
    }

    /// 1 行。
    ///
    /// **進んでいないときに 0 と書かない。** 0 は「測ったら 0 だった」と読めるが、実際は
    /// 測れていない — 欠測を数字に化けさせると、止まっているスケッチが「とても重い」と
    /// 誤読される。
    public static func line(rate: Double?, configuration: String) -> String {
        guard let rate else {
            return "速さ: 測れない — フレームが進んでいない (構成: \(configuration))"
        }
        return "速さ: \(String(format: "%.1f", rate)) fps (構成: \(configuration))"
    }
}
