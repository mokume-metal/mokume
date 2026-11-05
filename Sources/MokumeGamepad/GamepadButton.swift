// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import GameController

/// ゲームパッドのボタン。``Gamepad/isPressed(_:)`` に渡す。
///
/// 挙動の説明は ``Gamepad/isPressed(_:)`` にあり、ここは値の定義である ([ADR-0020] 決定 4)。
///
/// 中身は GameController がボタンに付けた名前 (`"Button A"` など) で、**変換せずにラップする** — キー
/// (``Key``) が macOS の仮想キーコードを、マウスボタン (``MouseButton``) が `NSEvent.buttonNumber` を
/// ラップするのと同じ設計である ([ADR-0034] 決定 2・6)。
///
/// **名前は刻印ではなく位置を指す。** ``a`` はフェイスボタンの下・``b`` は右・``x`` は左・``y`` は上で、
/// Xbox のパッドなら刻印のとおり、PlayStation のパッドなら × ○ □ △ に当たる (GameController が
/// そう割り当てる)。
///
/// 定数があるのはフェイスボタンの 4 つだけである。十字キー・ショルダーボタン・トリガーの定数は、使う作例か
/// 作品が出たときに追加する ([ADR-0034] 決定 2・[ADR-0043] 決定 2)。定数の無いボタンも ``init(rawValue:)`` に
/// GameController の名前を渡せば表せる。
///
/// **文字列リテラルからは作れない。** `isPressed("A")` は何も言わずに `false` を返すのではなく、
/// コンパイルエラーになる。
/// - Note: **`nonisolated` にしている** (``Key`` と同じ理由)。ボタンを表す値は、GameController の通知を受ける
///   側 (actor の隔離の外) と `draw()` の側 (main actor) の両方で比較される。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
/// [ADR-0043]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0043-features-start-from-examples.md
public nonisolated struct GamepadButton: Sendable, Hashable {
    /// GameController がボタンに付けた名前 (`"Button A"` など)。
    ///
    /// この名前を直接書く必要は無い — 定数のあるボタンは下の定数で書ける。記録した入力を
    /// 生成する側 (ツール・エージェント) のために公開している。
    public let rawValue: String

    /// 名前からボタンを作る。**未知の名前も表せる** (拒否しない)。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// **定数を宣言する extension にも `nonisolated` を書く** (``Key`` と同じ理由・
// [#1274](https://github.com/mokume-metal/mokume/issues/1274))。型に書いただけでは、ここで
// 宣言する静的な定数は既定の隔離 (main actor) に載る。
//
// 値は GameController 自身の定数から取る。手で綴った表を持たないので、綴りが 1 つずれて
// 「その釦だけ効かない」ことが起きない (ADR-0034 決定 3 が検査で塞いだ穴を、ここでは表を
// 持たないことで塞ぐ)。
nonisolated extension GamepadButton {
    /// フェイスボタンの下 (Xbox の A・PlayStation の ×)。
    public static let a = GamepadButton(rawValue: GCInputButtonA)
    /// フェイスボタンの右 (Xbox の B・PlayStation の ○)。
    public static let b = GamepadButton(rawValue: GCInputButtonB)
    /// フェイスボタンの左 (Xbox の X・PlayStation の □)。
    public static let x = GamepadButton(rawValue: GCInputButtonX)
    /// フェイスボタンの上 (Xbox の Y・PlayStation の △)。
    public static let y = GamepadButton(rawValue: GCInputButtonY)
}
