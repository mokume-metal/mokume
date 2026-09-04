// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 入ってきた 1 件が生む、スケッチ側の呼び出し。
///
/// **出来事ではなく呼び出しを配る。** 出来事から呼び出しへの写し方 (押下を伴う解放が
/// クリックになる、など) を ``InputState`` の側に置くと、判定に要る「適用する前の
/// 状態」を持っているところで決められる — 受け取る側が押下状態の写しを持たずに済む。
///
/// 窓からの実操作も外から送られたものも同じ ``InputState`` を通るので、**同じ出来事の
/// 並びは同じ呼び出しの並びを生む**。それが値として取れる形にしてあるので、2 つの経路が
/// 一致することを GPU 無しで検査できる。
enum InputCallback: Equatable, Sendable {
    /// 押された。
    case mousePressed
    /// 離された。
    case mouseReleased
    /// 押して離された。``mouseReleased`` の直後に続く。
    case mouseClicked
}
