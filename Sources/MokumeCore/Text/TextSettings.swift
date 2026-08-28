// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

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

/// 幅に収まらなくなったとき、どこで行を折るか。
public nonisolated enum TextWrap: Sendable, CaseIterable {
    /// 語の切れ目で折る。1 語が幅より長いときだけ、その語の中で折る。
    case word
    /// 文字の切れ目で折る。
    case character
}

/// 矩形へ流し込んだ結果。
///
/// **続きをどこから描くかを、呼んだ側が計算せずに済むように返す。**
public nonisolated struct TextFlow: Equatable, Sendable {
    /// 実際に置いた行数。
    public let lineCount: Int
    /// 実際に使った高さ (画素)。
    public let height: Float
    /// 置けずに残った文字。全部置けたなら空。
    public let remainder: String

    /// 収まりきらなかったか。
    public var isTruncated: Bool { !remainder.isEmpty }

    public init(lineCount: Int, height: Float, remainder: String) {
        self.lineCount = lineCount
        self.height = height
        self.remainder = remainder
    }
}

/// 文字の輪郭を成す、閉じた周ひとつ。
public nonisolated struct TextContour: Equatable, Sendable {
    /// 周を回る点。**最後の点から最初の点へ戻る**ものとして扱う。
    public let points: [SIMD2<Float>]
    /// 内側 (穴) か。`A` の三角や `o` の中が該当する。
    public let isHole: Bool

    public init(points: [SIMD2<Float>], isHole: Bool) {
        self.points = points
        self.isHole = isHole
    }
}
