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
///
/// **足し込みで数える量だけは、呼び出しが自分で運ぶ** ([ADR-0034] 決定 5)。位置は面から
/// 読めば「その出来事まで当てた値」になっているが、引きずった量とスクロール量は
/// フレームの頭から足し込むので、面から読むと**その出来事までの部分累計**になる。
///
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
enum InputCallback: Equatable, Sendable {
    /// 押された。
    case mousePressed
    /// 離された。
    case mouseReleased
    /// 押して離された。``mouseReleased`` の直後に続く。
    case mouseClicked
    /// 押していない間に動いた。
    case mouseMoved
    /// 押したまま動いた。**その 1 件で動いた量**を運ぶ。
    case mouseDragged(deltaX: Float, deltaY: Float)
    /// スクロールされた。**その 1 件ぶんの量**を運ぶ。
    case mouseWheel(deltaX: Float, deltaY: Float)
    /// キーが押された。
    case keyPressed
    /// キーが離された。
    case keyReleased
    /// 文字を生むキーが押された。``keyPressed`` の直後に続く。
    case keyTyped
}
