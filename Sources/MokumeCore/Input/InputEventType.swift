// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 出来事の種別の綴り。**書く側と読む側の正典。**
///
/// 綴りが割れると、症状は「触っても効かない」としか出ない — 書き手は書けたと思い、
/// 読み手は知らない種別として捨てるので、どちらも何も言わない ([ADR-0032] 決定 4)。
/// だから綴りを 1 箇所に置き、両側をここ経由にする。
///
/// ## 足すと止まる
///
/// ``InputEvent`` にケースを足すと ``InputEvent/wireType`` の網羅 `switch` が止まり、
/// ここへ綴りを足すと ``RawInputEvent/event`` の網羅 `switch` が止まる。**書けるのに
/// 読めない出来事は、コンパイルを通らない。**
///
/// 外から来た知らない綴りが `nil` に落ちる振る舞いは変わらない ([ADR-0018] 決定 3) —
/// それは `init(rawValue:)` が担う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
enum InputEventType: String, CaseIterable, Sendable {
    case mouseDown
    case mouseUp
    case mouseMoved
    case scrolled
    case keyDown
    case keyUp
}
