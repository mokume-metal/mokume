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
    /// 指定した位置が、字の囲みの上端 — 基準線から ``Sketch/textAscent()`` だけ上 — になる。
    ///
    /// 書体によっては、アクセントの付いた字がこの上端より上へ出る (``Sketch/textAscent()``)。
    case top
    /// 指定した位置が、文字の高さの中央になる。
    case center
    /// 指定した位置が**基準線** — 字が乗る線になる。既定。
    case baseline
    /// 指定した位置が、字の囲みの下端 — 基準線から ``Sketch/textDescent()`` だけ下 — になる。
    ///
    /// 字の下に付く記号は、この下端より下へ出ることがある (``Sketch/textDescent()``)。
    case bottom
}

/// 幅に収まらなくなったとき、どこで行を折るか。
public nonisolated enum TextWrap: Sendable, CaseIterable {
    /// 語の切れ目で折る。1 語が幅より長いときだけ、その語の中で折る。
    ///
    /// 改行しない空白 (U+00A0・U+202F・U+2007) は語の切れ目にならない — 字と同じに扱い、
    /// その前後で折らず、行の末尾から削りもしない。
    case word
    /// 文字の切れ目で折る。
    ///
    /// 切れ目に空白があれば、語の切れ目と同じく**まとめて消費する** — 行の末尾に収まった
    /// 空白も、溢れた空白も、どちらの行にも入らない。段落の頭の空白 (字下げ) と、切れ目に
    /// ならない行の中ほどの空白は行に残る。改行しない空白 (U+00A0・U+202F・U+2007) は
    /// 字と同じに扱うので、切れ目にあっても消費せず、次の行の頭に残る。
    case character
}

/// 矩形へ流し込んだ結果。
///
/// **続きをどこから描くかを、呼んだ側が計算せずに済むように返す。**
public nonisolated struct TextFlow: Equatable, Sendable {
    /// 実際に置いた行数。
    ///
    /// 元の文にある空の行 (改行が続いたところ) は 1 行に数える。**段落の末尾の空白で
    /// 折っても、空の行は数えない** — 切れ目の後ろに置く字が無いので、行にならない。
    public let lineCount: Int
    /// 実際に使った高さ (画素)。置いた行数 (``lineCount``) から決まる。
    public let height: Float
    /// 置けずに残った文字。全部置けたなら空。
    ///
    /// **元の文の後ろの部分そのもの**で、置いた最後の行との切れ目を消費した直後から
    /// 始まる — 語の切れ目なら次の語から、文字の切れ目なら次の字から、段落の切れ目なら
    /// 改行 1 つの次から。切れ目に空白が続いていれば、語の切れ目でも文字の切れ目でも、
    /// 続いた空白をまとめて消費する。段落の末尾の空白で折ったなら、その空白と改行 1 つを
    /// 消費して、次の段落の先頭から始まる。
    ///
    /// 消費した空白と改行は置いた行にも続きにも入らないが、**失われはしない**。元の文から
    /// 続きを除いた前半の末尾に、そのままの数で残っている。
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
    /// 内側 (穴) か。`o` の中が該当する。
    ///
    /// 穴として返るかは**書体による** — 既定の書体の `A` は重なった外周として返り、
    /// 三角はこれの立った周にならない (``Sketch/textOutline(_:_:_:)``)。
    public let isHole: Bool

    public init(points: [SIMD2<Float>], isHole: Bool) {
        self.points = points
        self.isHole = isHole
    }
}
