// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれる観測の要求。
///
/// 形の正典は `Schemas/observe-request.schema.json`。**知らない鍵は無視する**
/// ([ADR-0018] 決定 3) ので、書き手が新しい鍵を足しても古い実装は壊れない。
///
/// ## 間隔はフレーム数で数える
///
/// ``every`` は秒ではなくフレームで数える。既定の時計はフレーム番号から導くので、
/// フレームで数えれば**同じスケッチを 2 回走らせれば同じ列が返る**。秒で指定しても
/// 結局はフレームへ丸めることになり、実時間の時計に差し替えた経路では列が走らせる
/// たびに変わってしまう。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
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

    /// この要求の識別子。応答はこれを echo する。
    public let id: String
    /// 書き出す画像の縮小率 (1 = 実寸)。
    public let scale: Double
    /// 撮る枚数。
    public let count: Int
    /// 何フレームおきに撮るか。
    public let every: Int

    public init(id: String, scale: Double = 1, count: Int = 1, every: Int = 1) {
        self.id = id
        self.scale = scale
        self.count = count
        self.every = every
    }

    /// 上限で切った枚数と間隔、そして切ったことを伝えることわり。
    ///
    /// **黙って切り詰めない。** 頼んだ枚数と返った枚数が違うことに応答から気付けないと、
    /// 読み手は「動きが途中で止まった」と「上限で切られた」を区別できない。
    ///
    /// 切るのは要求を解いた後の別の段にしてある — 要求そのものは書き手が置いたままの
    /// 値を保ち、応答の `id` と並べて「何を頼み、何が返ったか」を突き合わせられる。
    func clamped() -> (count: Int, every: Int, warnings: [String]) {
        var warnings: [String] = []
        let count = max(1, min(count, Self.maximumCount))
        if count != self.count {
            warnings.append("撮る枚数を \(self.count) から \(count) にしました (上限 \(Self.maximumCount) 枚)")
        }
        let every = max(1, min(every, Self.maximumEvery))
        if every != self.every {
            warnings.append(
                "撮る間隔を \(self.every) から \(every) フレームにしました (上限 \(Self.maximumEvery) フレーム)")
        }
        return (count, every, warnings)
    }

    private enum CodingKeys: String, CodingKey {
        case id, scale, count, every
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        self.count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        self.every = try container.decodeIfPresent(Int.self, forKey: .every) ?? 1
    }
}
