// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 並べた頂点をどう読むか。
///
/// - Note: **隔離の外に置く** — 設定を表す値型は隔離を跨いで読まれる
///   (`BlendMode` の説明を参照)。
public nonisolated enum VertexKind: Sendable, Equatable {
    /// 周をなす 1 つの形として読む (既定)。凹んでいても穴があってもよい。
    case polygon
    /// 1 点ずつ独立した点として読む。
    case points
    /// 2 点ずつ独立した線として読む。奇数個の余りは捨てる。
    case lines
    /// 3 点ずつ独立した三角形として読む。余りは捨てる。
    case triangles
    /// 帯として読む。**3 つ目からは直前の 2 点を使い回す** — n 点で n-2 枚。
    case triangleStrip
    /// 扇として読む。**最初の 1 点と直前の 1 点を使い回す** — n 点で n-2 枚。
    case triangleFan
}

/// 並べ終えた形を閉じるか。
public nonisolated enum ShapeEnd: Sendable, Equatable {
    /// 最後の点から最初の点へ戻らない。
    case open
    /// 最後の点から最初の点へ戻る。
    case close
}
