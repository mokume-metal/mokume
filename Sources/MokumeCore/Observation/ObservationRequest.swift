// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれる観測の要求。
///
/// 形の正典は `Schemas/observe-request.schema.json`。**知らない鍵は無視する**
/// ([ADR-0018] 決定 3) ので、書き手が新しい鍵を足しても古い実装は壊れない。
///
/// ## 同じ時刻で比較する
///
/// `time: 3` を指定すると、3秒目を1枚描き直して撮る。色を編集して保存した後も、
/// 新しいidで同じ秒を指定すれば同じ構図で比べられる。秒はFloatに丸める。
/// **画面とdrawの副作用は残る。** deltaTimeは0、frameCountは1進み、次は元の時計へ戻る。
/// 状態の巻き戻しではなく、時刻と他の入力から絵が決まる作品向けである。
/// noLoopは停止を保つ。外部pause、録画中、count/everyが1以外なら理由を返す。
/// 指定フレーム内でのbeginRecordも断る。通常観測はtimeを省く。
/// 応答にappliedTimeがあり、目録と同じ秒かを必ず確認する。旧版はtimeを無視することがある。
///
/// ## 間隔はフレーム数で数える
///
/// ``every`` は秒ではなくフレームで数える。秒で指定しても結局はフレームへ丸めることに
/// なるためで、数えるのは**実際に描けたフレーム**である。
///
/// **撮れた枚の時刻の間隔は揃わない。** 観測を受けるのは `mokume run` / `watch` が
/// 走らせているスケッチで、その入口は実時計を渡す (`SketchApplication` が
/// ``Clock/wallClock`` で組む) — 撮っている間は絵の書き出しでフレームが重くなるので、
/// 間隔は描けた速さのぶんだけ伸び縮みする。**並べるには応答の目録 (`frames`) の各行の
/// `time` を読む**。枚数のまま並べると、黙って速さの狂った動きができる ([#1285])。
///
/// 時計をフレーム番号から導く経路 (``SketchRuntime`` を直接組む検査・ヘッドレス) では
/// 間隔も揃い、同じスケッチを 2 回走らせれば同じ列が返る。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#1285]: https://github.com/mokume-metal/mokume/issues/1285
public struct ObservationRequest: ExchangeRequest, Equatable, Sendable {
    /// 撮れる枚数の上限。60fps で 2 秒ぶん。
    ///
    /// 撮った絵は 1 枚ずつ区画へ書き出されるので、際限なく頼めるとディスクが埋まる。
    /// 動きが正しいかを見るには十分な長さで切る。
    public static let maximumCount = 120
    /// 間隔の上限 (フレーム)。60fps で 1 秒に 1 枚。
    ///
    /// 間隔が長いほど列が返るまでの待ちが伸びる。読み手の待ちが尽きると、応答は
    /// 後から書かれるのに読み手だけが諦めた状態になる。
    public static let maximumEvery = 60
    /// 撮れる枚数の下限。0 枚の列は撮り終わりが来ない。
    static let minimumCount = 1
    /// 間隔の下限 (フレーム)。毎フレーム撮るより詰めることはできない。
    static let minimumEvery = 1

    /// この要求の識別子。応答はこれを echo する。
    public let id: String
    /// 書き出す画像の縮小率 (1 = 実寸)。
    public let scale: Double
    /// 撮る枚数。
    public let count: Int
    /// 何フレームおきに撮るか。
    public let every: Int
    /// 指定した秒で1枚描き直す。省略時は直近の絵を読むだけ。
    /// `deltaTime` は0、番号は1進む。画面と `draw()` の副作用は残り、巻き戻しではない。
    public let time: Double?

    /// JSON の数として読めても、時刻として使えない要求は応答で断る。
    var timeWarning: String? {
        guard let time else { return nil }
        guard time.isFinite, time >= 0, time <= Double(Float.greatestFiniteMagnitude) else {
            return "time must be finite, non-negative seconds within the Float range"
        }
        guard count == 1, every == 1 else {
            return "A specified time requires count=1 and every=1"
        }
        return nil
    }

    public init(id: String, scale: Double = 1, count: Int = 1, every: Int = 1, time: Double? = nil) {
        self.id = id
        self.scale = scale
        self.count = count
        self.every = every
        self.time = time
    }

    /// 範囲の端で丸めた枚数と間隔、そして丸めたことを伝えることわり。
    ///
    /// **黙って切り詰めない。** 頼んだ枚数と返った枚数が違うことに応答から気付けないと、
    /// 読み手は「動きが途中で止まった」と「上限で切られた」を区別できない。ことわりは
    /// **切った端を名乗る** — 上で切れば上限を、下 (0・負) で切れば下限を言う。どちらの
    /// 端でも上限を名乗っていたので、読み手は切られた理由を取り違えた ([#1699])。
    ///
    /// 切るのは要求を解いた後の別の段にしてある — 要求そのものは書き手が置いたままの
    /// 値を保ち、応答の `id` と並べて「何を頼み、何が返ったか」を突き合わせられる。
    ///
    /// [#1699]: https://github.com/mokume-metal/mokume/issues/1699
    func clamped() -> (count: Int, every: Int, warnings: [String]) {
        var warnings: [String] = []
        let count = Self.clamp(self.count, into: Self.minimumCount...Self.maximumCount)
        if let bound = count.bound {
            warnings.append(
                "The number of shots went from \(self.count) to \(count.value) (\(bound))")
        }
        let every = Self.clamp(self.every, into: Self.minimumEvery...Self.maximumEvery)
        if let bound = every.bound {
            warnings.append(
                "The interval went from \(self.every) to \(every.value) frames (\(bound))")
        }
        return (count.value, every.value, warnings)
    }

    /// 範囲へ丸めた値と、丸めたなら切った端を名乗る括弧の中身。範囲の中なら `nil`。
    private static func clamp(_ value: Int, into range: ClosedRange<Int>)
        -> (value: Int, bound: String?)
    {
        if value > range.upperBound { return (range.upperBound, "the ceiling is \(range.upperBound)") }
        if value < range.lowerBound { return (range.lowerBound, "the floor is \(range.lowerBound)") }
        return (value, nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, scale, count, every, time
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        self.count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        self.every = try container.decodeIfPresent(Int.self, forKey: .every) ?? 1
        // 型が違っても「時刻なし」として成功させない。NaNは内部の拒否用で応答には書かない。
        self.time = container.contains(.time)
            ? (try? container.decode(Double.self, forKey: .time)) ?? .nan : nil
    }
}
