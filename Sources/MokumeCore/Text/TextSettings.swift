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
    /// 指定した位置が、字の囲みの上端 — 基準線から ``SketchPart/textAscent()`` だけ上 — になる。
    ///
    /// 書体によっては、アクセントの付いた字がこの上端より上へ出る (``SketchPart/textAscent()``)。
    case top
    /// 指定した位置が、文字の高さの中央になる。
    case center
    /// 指定した位置が**基準線** — 字が乗る線になる。既定。
    case baseline
    /// 指定した位置が、字の囲みの下端 — 基準線から ``SketchPart/textDescent()`` だけ下 — になる。
    ///
    /// 字の下に付く記号は、この下端より下へ出ることがある (``SketchPart/textDescent()``)。
    case bottom
}

/// 幅に収まらなくなったとき、どこで行を折るか。
public nonisolated enum TextWrap: Sendable, CaseIterable {
    /// 語の切れ目で折る。1 語が幅より長いときだけ、その語の中で折る。
    ///
    /// **語の切れ目は、Unicode の行分割の規則 (UAX #14) で決める。** 欧文では空白の後ろ
    /// (ハイフンやスラッシュの後ろも) で、空白の無い和文では字と字の間で折れる。行頭には
    /// 「、」「。」「」」が来ず、行末には「「」が残らない。**小書きの仮名と長音 (「ッ」「ー」)
    /// の前では折りうる** — 厳しい禁則 (行頭に置かない字を増やすこと) は掛けない。折る位置は、
    /// いまの書体で測った字ごとの送り幅の合計で決める。
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
    /// 続いた空白をまとめて消費する。空白の無い切れ目 (和文の字と字の間) では何も消費しない。段落の末尾の空白で折ったなら、その空白と改行 1 つを
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
    ///
    /// ``SketchPart/textOutline(_:_:_:)`` が返す周は、外側 (``isHole`` が `false`) が面で時計回りに見える向き、穴が逆回りで、
    /// 書体の巻きによらずそろっている。
    public let points: [Vector2]
    /// 点の SIMD の値。**内部の計算 (間引き・並べ直し) はこちらを通る** — 公開の型 (``points``) へ
    /// 計算で包み直すと、`points[i]` を添字で引く書き方が毎回全部を包み直して二乗の費用になるので、
    /// 両方を持つ (同じ大きさの値で、周 1 つにつき数 KB・#2617)。
    let outline: [SIMD2<Float>]
    /// 内側 (穴) か。`o` の中が該当する。周の向きで決まる (穴は外側の周と逆回り)。
    ///
    /// 穴として返るかは**書体による** — 既定の書体の `A` は重なった外周として返り、
    /// 三角はこれの立った周にならない (``SketchPart/textOutline(_:_:_:)``)。
    public let isHole: Bool

    public init(points: [Vector2], isHole: Bool) {
        self.points = points
        self.outline = points.map(\.simd)
        self.isHole = isHole
    }

    init(outline: [SIMD2<Float>], isHole: Bool) {
        self.points = outline.map { Vector2($0) }
        self.outline = outline
        self.isHole = isHole
    }
}

/// 文字列の墨が載る範囲 (``SketchPart/textBounds(_:_:_:)``)。
///
/// **送り幅ではなく墨を囲む。** 字の左右に書体が付けている余白は入らない。
public nonisolated struct TextBounds: Equatable, Sendable {
    /// 左端 (画素)。
    public let x: Float
    /// 上端 (画素)。**y は下向き**なので、いちばん小さい y である。
    public let y: Float
    /// 幅 (画素)。
    public let width: Float
    /// 高さ (画素)。
    public let height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
