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

    /// 名乗る先が端末か。
    ///
    /// **読むのはここだけ。** 判定は ``announces(configuration:isTerminal:)`` が持つ。
    static var isTerminal: Bool { isatty(STDOUT_FILENO) != 0 }

    /// 端末へ書くときの飾り。行頭へ戻して消してから書く — **同じ 1 行を書き換える。**
    ///
    /// 見張る道具の側にも同じ綴りがある。規約は文章で共有し、実装はそれぞれが持つ
    /// (この綴りを外へ出すかは、外から使う人が現れてから決める)。
    static let rewrite = "\r\u{1B}[2K"

    /// 名乗るか。
    ///
    /// **鍵が与えられていて、かつ端末のときだけ。** 速さは走らせている間に人が読む
    /// 生きた数字で、記録に毎秒 1 行残っても情報にならない — 1 時間で 3600 行になり、
    /// その間に起きた作り直しの失敗を埋める ([#685])。機械が読む口は観測の側にあり、
    /// そちらは 1 バイトも変わらない。
    ///
    /// [#685]: https://github.com/mokume-metal/mokume/issues/685
    static func announces(configuration: String?, isTerminal: Bool) -> Bool {
        configuration != nil && isTerminal
    }

    /// 1 行。
    ///
    /// **進んでいないときに 0 と書かない。** 0 は「測ったら 0 だった」と読めるが、実際は
    /// 測れていない — 欠測を数字に化けさせると、止まっているスケッチが「とても重い」と
    /// 誤読される。
    ///
    /// 推移を持たない形。推移の無い行 (``line(rate:configuration:history:)`` に空の推移を
    /// 渡したもの) と同じ文字列になる。
    public static func line(rate: Double?, configuration: String) -> String {
        line(rate: rate, configuration: configuration, trend: "")
    }

    /// 直近の推移を添えた 1 行 (#3424)。
    ///
    /// 推移は現在値の直後・構成の括弧の直前に、空白 1 つで区切って置く。**1 行のまま**
    /// (改行を含まず、構成は同じ行に残る — [ADR-0029] 決定 3)。推移が空 (最初の 1 秒より前)
    /// なら、推移を持たない形と同じ文字列になる。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func line(rate: Double?, configuration: String, history: History) -> String {
        line(rate: rate, configuration: configuration, trend: history.trend)
    }

    private static func line(rate: Double?, configuration: String, trend: String) -> String {
        let spaced = trend.isEmpty ? "" : " \(trend)"
        guard let rate else {
            return "Rate: cannot tell — frames are not advancing\(spaced) (\(configuration))"
        }
        return "Rate: \(String(format: "%.1f", rate)) fps\(spaced) (\(configuration))"
    }

    /// 速さの直近の推移 (#3424)。**子 (このプロセス) の中にだけ持つ。**
    ///
    /// 1 文字は経過した 1 秒を表す。呼ばれた回数ではない — 呼びが遅れて 2 秒以上空いたら、
    /// 空いた秒は欠測で埋める。**前の値を空いた秒へ写さない** (同じ値を時間の違う点へ
    /// 黙って複製しない)。
    ///
    /// 作り直しで子が替わると、推移は新しい子の空から始まる。環境変数や時計の受け渡しで
    /// 運ばないので、版の違う 2 つの子の値が 1 本の推移に見えることはない。
    ///
    /// **時計は持たない。** 標本を取った時刻は呼び出し元が渡す — 時計を差し替えなくても
    /// 経過時間の扱いを検査できる。投げる経路を持たず、フレームの進行にも触れない
    /// ([ADR-0029] 決定 5 の 1 番目)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    struct History: Equatable {
        /// 残す秒数。古いほうから落ちる。
        static let capacity = 30

        /// 値の無い秒の文字。**最も低い棒にも 0 にもしない** (ADR-0029 決定 3)。
        static let missing: Character = "·"

        /// 棒の段 (低い順)。
        private static let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

        /// 縦軸の上端。起動のときに検めた宣言値で、**自動の目盛りにしない** — 軸が動いた
        /// だけの差を速さの変化に見せないため。
        private let declaredFrameRate: Double
        /// 古いほうが先頭。`nil` は欠測の秒。
        private(set) var samples: [Double?] = []
        /// 最後に標本を取った時刻 (単調な時計の秒)。
        private var lastTime: Double?

        init(declaredFrameRate: Int) {
            self.declaredFrameRate = Double(max(1, declaredFrameRate))
        }

        /// 1 つの標本を足す。`time` は単調な時計の秒。
        ///
        /// 前の標本から 1 秒より長く空いていたら、その間の秒は欠測で埋めてから足す。
        /// 時計が戻った・止まった (経過が 1 秒に満たない) ときも 1 秒の進みとして数える —
        /// 呼ばれた 1 回は、少なくとも 1 文字の重みを持つ。
        mutating func record(rate: Double?, at time: Double) {
            if let lastTime {
                let elapsed = Int(max(1, (time - lastTime).rounded()))
                append(Array(repeating: nil, count: min(elapsed - 1, Self.capacity)))
            }
            lastTime = time
            append([rate.flatMap { $0.isFinite ? $0 : nil }])
        }

        private mutating func append(_ new: [Double?]) {
            samples.append(contentsOf: new)
            if samples.count > Self.capacity {
                samples.removeFirst(samples.count - Self.capacity)
            }
        }

        /// 推移の文字列。古いほうが左。標本が無ければ空。
        var trend: String {
            String(samples.map(bar))
        }

        /// 1 秒の値 `r` を `ratio = min(r / F, 1)` の 8 段へ。`F` を越えたら最も高い棒。
        private func bar(_ rate: Double?) -> Character {
            guard let rate else { return Self.missing }
            let ratio = min(max(rate, 0) / declaredFrameRate, 1)
            let level = min(8, max(1, Int((ratio * 8).rounded(.up))))
            return Self.bars[level - 1]
        }
    }

    /// 単調な時計の秒。**眠っていた間も進む** (`CLOCK_MONOTONIC`) ので、眠って起きた後は
    /// その間が欠測として並ぶ。壁時計は調整で飛ぶので使わない。
    static var monotonicSeconds: Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
