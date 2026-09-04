// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// キーボードのキー。
///
/// 意味の説明は ``Sketch/keyCode`` が正本で、ここは値の定義である ([ADR-0020] 決定 4)。
///
/// 綴りは W3C `KeyboardEvent.code` の語彙に沿う。**表しているのは打たれた文字ではなく
/// キーの物理的な位置**なので、配列を変えても同じ指の位置が同じ綴りになる。打たれた
/// 文字が要るなら ``Sketch/key`` を読む。
///
/// 名前を持たないキーも ``init(rawValue:)`` で表せる。**外から任意の符号が送られて
/// くる**ので ([ADR-0018] 決定 1)、名前の付いたものしか表せない形にすると、知らない
/// キーを押しただけで出来事が消える。
/// - Note: **隔離の外に置く。** ライブラリ全体が main actor を既定の隔離としているので
///   ([ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) 決定 1)、
///   何も書かないと `Hashable` の準拠まで隔離され、隔離の外から比べられなくなる。
///   **キーを表す値は隔離を跨いで読まれる**ので、型ごと外に出す。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated struct Key: Sendable, Hashable {
    /// macOS の仮想キーコード。**外から送る `code` と同じ数。**
    ///
    /// この数を手で書く必要は無い — 名前の付いたキーは下の定数で書ける。線を組み立てる
    /// 側 (道具・エージェント) のために公開している。
    public let rawValue: Int

    /// 符号からキーを作る。**知らない符号も表せる** (弾かない)。
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

// MARK: - 文字を打つキー

extension Key {
    /// A の位置のキー。
    public static let a = Key(rawValue: 0)
    /// B の位置のキー。
    public static let b = Key(rawValue: 11)
    /// C の位置のキー。
    public static let c = Key(rawValue: 8)
    /// D の位置のキー。
    public static let d = Key(rawValue: 2)
    /// E の位置のキー。
    public static let e = Key(rawValue: 14)
    /// F の位置のキー。
    public static let f = Key(rawValue: 3)
    /// G の位置のキー。
    public static let g = Key(rawValue: 5)
    /// H の位置のキー。
    public static let h = Key(rawValue: 4)
    /// I の位置のキー。
    public static let i = Key(rawValue: 34)
    /// J の位置のキー。
    public static let j = Key(rawValue: 38)
    /// K の位置のキー。
    public static let k = Key(rawValue: 40)
    /// L の位置のキー。
    public static let l = Key(rawValue: 37)
    /// M の位置のキー。
    public static let m = Key(rawValue: 46)
    /// N の位置のキー。
    public static let n = Key(rawValue: 45)
    /// O の位置のキー。
    public static let o = Key(rawValue: 31)
    /// P の位置のキー。
    public static let p = Key(rawValue: 35)
    /// Q の位置のキー。
    public static let q = Key(rawValue: 12)
    /// R の位置のキー。
    public static let r = Key(rawValue: 15)
    /// S の位置のキー。
    public static let s = Key(rawValue: 1)
    /// T の位置のキー。
    public static let t = Key(rawValue: 17)
    /// U の位置のキー。
    public static let u = Key(rawValue: 32)
    /// V の位置のキー。
    public static let v = Key(rawValue: 9)
    /// W の位置のキー。
    public static let w = Key(rawValue: 13)
    /// X の位置のキー。
    public static let x = Key(rawValue: 7)
    /// Y の位置のキー。
    public static let y = Key(rawValue: 16)
    /// Z の位置のキー。
    public static let z = Key(rawValue: 6)

    /// 数字列の 0。**テンキーの 0 とは別のキー。**
    public static let digit0 = Key(rawValue: 29)
    /// 数字列の 1。
    public static let digit1 = Key(rawValue: 18)
    /// 数字列の 2。
    public static let digit2 = Key(rawValue: 19)
    /// 数字列の 3。
    public static let digit3 = Key(rawValue: 20)
    /// 数字列の 4。
    public static let digit4 = Key(rawValue: 21)
    /// 数字列の 5。
    public static let digit5 = Key(rawValue: 23)
    /// 数字列の 6。
    public static let digit6 = Key(rawValue: 22)
    /// 数字列の 7。
    public static let digit7 = Key(rawValue: 26)
    /// 数字列の 8。
    public static let digit8 = Key(rawValue: 28)
    /// 数字列の 9。
    public static let digit9 = Key(rawValue: 25)
}

// MARK: - 文字を打たないキー

extension Key {
    /// 空白。
    public static let space = Key(rawValue: 49)
    /// 改行 (Mac のキーボードでは return と刻まれている)。
    public static let enter = Key(rawValue: 36)
    /// 取り消し。
    public static let escape = Key(rawValue: 53)
    /// 字送り。
    public static let tab = Key(rawValue: 48)
    /// 手前を消す (Mac のキーボードでは delete と刻まれている)。
    ///
    /// **W3C の綴りに従って `backspace` と呼ぶ。** あちらの `Delete` は前を消すほう
    /// (Mac では fn + delete) なので、刻印のまま `delete` と名乗ると別のキーと重なる。
    public static let backspace = Key(rawValue: 51)

    /// ← の矢印。
    public static let arrowLeft = Key(rawValue: 123)
    /// → の矢印。
    public static let arrowRight = Key(rawValue: 124)
    /// ↓ の矢印。
    public static let arrowDown = Key(rawValue: 125)
    /// ↑ の矢印。
    public static let arrowUp = Key(rawValue: 126)
}
