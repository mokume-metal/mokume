// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 窓に出す数字。
///
/// **観測の応答と同じ集計器から採る** ([ADR-0030] 決定 7)。窓は読み手であり、自分で
/// 平均を取らない — 一致させるのは源であって経路ではない。
///
/// ファイルの応答を窓に読ませる形は採らない。応答を組む手間 (メモリ・熱の問い合わせ)
/// が毎フレームの描画に乗るためである。**同じ源を 2 人が読む**のであって、片方が
/// もう片方の出力を読むのではない。
///
/// ## 測れていない値は持たない
///
/// 速さもフレーム時間も、起動直後と止めている間は測れていない。**それを 0 で表さない** —
/// 測れた 0 と区別が付かなくなる。応答が鍵ごと省くのと同じ形にし、窓は「—」と描く。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct FrameNumbers: Equatable {
    /// 進めた枚数。
    let frameCount: Int
    /// スケッチの時刻 (秒)。
    let time: Double
    /// 直近で実際に出ている速さ。**測れていなければ `nil`。**
    let frameRate: Double?
    /// 直近のフレーム時間の平均 (ミリ秒)。**測れていなければ `nil`。**
    let frameTimeMs: Double?
}
