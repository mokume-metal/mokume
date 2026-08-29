// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描く細かさと出す細かさの間を、どうやって埋めるか。
///
/// 意味の説明は利用者が最初に触る層 (``Sketch``) が正本で、ここは値の定義である
/// ([ADR-0020] 決定 4)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum Upscale: Equatable, Sendable {
    /// そのフレームの画素だけから埋める。**同じ入力からは同じ絵が出る。**
    case spatial

    /// 前のフレームの結果も使って埋める。**同じ入力から同じ絵が出なくなる。**
    ///
    /// [ADR-0015] 決定 2 の言う代償はこれである。フレーム N の絵はそこへ至る経路に
    /// 依存し、単独で描いた N と 0 から進めて得た N が一致しない。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    case temporal

    /// 前のフレームの結果を使うか。**決定論に依る仕組みはここを読む。**
    public var usesFrameHistory: Bool { self == .temporal }
}
