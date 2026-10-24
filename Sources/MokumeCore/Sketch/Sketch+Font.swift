// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 書体のファイルを読む口。
extension SketchPart {
    /// 書体のファイル (`.ttf`・`.otf`・`.ttc`・`.otc`) を読む。読み終わるまで返らない。返った ``Font`` は
    /// ``textFont(_:)-(Font)`` へ渡して使う。
    ///
    /// <!-- example: 文脈 var display: Font? -->
    /// ```swift
    /// func setup() throws {
    ///     display = try loadFont("assets/fonts/Display.otf")
    /// }
    ///
    /// func draw() {
    ///     if let display { textFont(display) }
    ///     text("mokume", 40, 80)
    /// }
    /// ```
    ///
    /// **探す場所と順は ``loadImage(_:)`` と同じ** (``assetURL(_:)``) — 作業ディレクトリ、束ねた資源の置き場、
    /// 実行ファイルの隣の包みの中、の順に見て、最初に在ったものを使う。`/` で始まる名前はそのまま使う。
    /// 書体を作品に同梱すれば、配った先の Mac に同じ書体が入っているかに、絵が依らない。
    ///
    /// **読んだ書体は、この環境へ登録しない。** 同じ名前の書体が入っていても、``textFont(_:)-(String)``
    /// の結果は変わらず、他のアプリにも見えない。ファイルが複数の面を持つとき (`.ttc` など) は、
    /// ``textStyle(_:)``・``textWeight(_:)`` がその中から面を選ぶ。**可変書体は 1 つの値** で、太さは
    /// ``textWeight(_:)`` で動かす。
    ///
    /// **同じファイルは同じ値になる。** 更新されないまま何度読んでも、返る ``Font`` は等しい。それでも
    /// **`setup()` で 1 度読む** — 読むたびにファイルを開いて解析する。`draw()` の中で呼ぶと、口の名前を
    /// 添えて 1 度だけ知らせる。
    ///
    /// - Throws: 見つからないとき・見つかったが開けないとき (ディレクトリだった・読む権利が無い。解けた
    ///   場所が載る ``FontFailure/unopenable(path:location:reason:)``)・書体として読めないときに
    ///   ``FontFailure``。**走っていなくても読める** — 面を使わないので、``FontFailure`` に
    ///   「走っていない」の場合は無い。
    // shot: 撮れない 読んだ書体を返す口で、書体のファイルはリポジトリに置けない。使った絵は textFont(_:) の説明が持つ
    public func loadFont(_ path: String) throws(FontFailure) -> Font {
        Self.noticeBlockingLoad("loadFont(_:)", instead: nil)
        return try Font.load(path)
    }
}
