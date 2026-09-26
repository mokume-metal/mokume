// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// マウスの釦。
///
/// 意味の説明は ``Sketch/mouseButton`` が正本で、ここは値の定義である ([ADR-0020] 決定 4)。
///
/// 番号は macOS の `NSEvent.buttonNumber` で、0 が左 (主)・1 が右 (副)・2 が中である。
/// **ブラウザの `MouseEvent.button` (1 が中・2 が副) とは 1 と 2 の並びが逆**なので、
/// 数で比べる書き方を面に置かない — 定数の名前で書く。
///
/// 名前を持たない釦も ``init(rawValue:)`` で表せる。**外から任意の番号が送られて
/// くる**ので ([ADR-0018] 決定 1)、名前の付いたものしか表せない形にすると、戻る・進む
/// のような 4 番目以降の釦を押しただけで出来事が消える。
///
/// **数のリテラルからは作れない。** 手本を写した `mouseButton == 37` や、ブラウザの番号を
/// 覚えている人の `mouseButton == 2` は、黙って別の釦になるのではなくコンパイルで止まる。
/// - Note: **隔離の外に置く。** ライブラリ全体が main actor を既定の隔離としているので
///   ([ADR-0010](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md) 決定 1)、
///   何も書かないと `Hashable` の準拠まで隔離され、隔離の外から比べられなくなる。
///   **釦を表す値は隔離を跨いで読まれる**ので、型ごと外に出す (``Key`` と同じ)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated struct MouseButton: Sendable, Hashable {
    /// macOS の `NSEvent.buttonNumber`。**外から送る `button` と同じ数。**
    ///
    /// この数を手で書く必要は無い — 名前の付いた釦は下の定数で書ける。線を組み立てる
    /// 側 (道具・エージェント) のために公開している。
    public let rawValue: Int

    /// 番号から釦を作る。**知らない番号も表せる** (弾かない)。
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

// **定数を宣言する extension にも `nonisolated` を書く** (``Key`` と同じ理由・
// [#1274](https://github.com/mokume-metal/mokume/issues/1274))。型に書いただけでは、
// ここで宣言する静的な定数は既定の隔離 (main actor) に載る。
nonisolated extension MouseButton {
    /// 左の釦 (主釦)。手本の `LEFT`。
    public static let left = MouseButton(rawValue: 0)
    /// 右の釦 (副釦)。手本の `RIGHT`。
    public static let right = MouseButton(rawValue: 1)
    /// 中の釦 (ホイールの押し込み)。手本の `CENTER`。
    public static let center = MouseButton(rawValue: 2)
}
