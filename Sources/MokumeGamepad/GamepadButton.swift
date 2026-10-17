// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import GameController

/// ゲームパッドの釦。``Gamepad/isPressed(_:)`` に渡す。
///
/// 意味の説明は ``Gamepad/isPressed(_:)`` が正本で、ここは値の定義である ([ADR-0020] 決定 4)。
///
/// 中身は GameController が釦に付けた名前 (`"Button A"` など) で、**変換せずに包む** — キー
/// (``Key``) が macOS の仮想キーコードを、マウスの釦 (``MouseButton``) が `NSEvent.buttonNumber` を
/// 包むのと同じ判断である ([ADR-0034] 決定 2・6)。
///
/// **名前は印字ではなく位置を指す。** ``a`` は面の下・``b`` は右・``x`` は左・``y`` は上の釦で、
/// Xbox のパッドなら印字のとおり、PlayStation のパッドなら × ○ □ △ に当たる (GameController が
/// そう割り当てる)。
///
/// 名前を付けてあるのは面の 4 つだけである。十字キー・肩・引き金の名前は、使う作例か作品が出た
/// ときに足す ([ADR-0034] 決定 2・[ADR-0043] 決定 2)。名前の無い釦も ``init(rawValue:)`` に
/// GameController の名前を渡せば表せる。
///
/// **文字列のリテラルからは作れない。** `isPressed("A")` は黙って偽になるのではなく、
/// コンパイルで止まる。
/// - Note: **隔離の外に置く** (``Key`` と同じ理由)。釦を表す値は、GameController の知らせを受ける
///   側 (隔離の外) と `draw()` の側 (main actor) の両方で比べられる。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
/// [ADR-0043]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0043-features-start-from-examples.md
public nonisolated struct GamepadButton: Sendable, Hashable {
    /// GameController が釦に付けた名前 (`"Button A"` など)。
    ///
    /// この名前を手で書く必要は無い — 名前の付いた釦は下の定数で書ける。記録した入力を
    /// 組み立てる側 (道具・エージェント) のために公開している。
    public let rawValue: String

    /// 名前から釦を作る。**知らない名前も表せる** (弾かない)。
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
    /// 面の下の釦 (Xbox の A・PlayStation の ×)。
    public static let a = GamepadButton(rawValue: GCInputButtonA)
    /// 面の右の釦 (Xbox の B・PlayStation の ○)。
    public static let b = GamepadButton(rawValue: GCInputButtonB)
    /// 面の左の釦 (Xbox の X・PlayStation の □)。
    public static let x = GamepadButton(rawValue: GCInputButtonX)
    /// 面の上の釦 (Xbox の Y・PlayStation の △)。
    public static let y = GamepadButton(rawValue: GCInputButtonY)
}
