// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 書体の太さと傾き。
///
/// `nonisolated` にしてあるのは、`Equatable` の適合まで隔離に巻き込むと、隔離の外から
/// 値を比べられなくなるため (設定を表す値の型はどれも同じ理由で `nonisolated`)。
public nonisolated enum TextStyle: Sendable, CaseIterable {
    /// そのまま。
    case normal
    /// 太く。
    case bold
    /// 傾けて。
    case italic
    /// 太く傾けて。
    case boldItalic
}

/// 文字列を、指定した位置の左右どちら側へ置くか。
public nonisolated enum HorizontalTextAlign: Sendable, CaseIterable {
    /// 指定した位置から右へ流す。
    case left
    /// 指定した位置を文字列の中央にする。
    case center
    /// 指定した位置で文字列が終わる。
    case right
}

/// 文字列を、指定した位置の上下どこに合わせるか。
public nonisolated enum VerticalTextAlign: Sendable, CaseIterable {
    /// 指定した位置が、いちばん高い字の上端になる。
    case top
    /// 指定した位置が、文字の高さの中央になる。
    case center
    /// 指定した位置が**基準線** — 字が乗る線になる。既定。
    case baseline
    /// 指定した位置が、いちばん低い字の下端になる。
    case bottom
}
