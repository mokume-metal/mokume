// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 列が読んでいる面の中身が何を表しているか。
///
/// **同じシェーダが 2 種類の面を読む。** 字形は「その画素をどれだけ覆っているか」の
/// 一枚で、画像は色そのものである。掛け方が違うので、どちらを読んでいるかを列ごとに
/// 渡す。
///
/// `nonisolated` にしてあるのは、他の設定を表す値の型と同じ理由 (``TextStyle``)。
nonisolated enum TextureKind: UInt32, Sendable, CaseIterable {
    /// 覆っている割合。塗りの色に掛ける (字形・図形が読む白い区画)。
    case coverage = 0
    /// 色そのもの。色掛けを掛ける (画像)。
    case color = 1
}
