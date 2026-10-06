// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// SVG を読んで、保持した形にする。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 読み解きは ``SVGFile``、形にするのは面 (``Canvas``) の記録で、どちらも公開しない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {
    /// SVG のファイルを読み、保持した形 (``Shape``) にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var logo: Shape? -->
    /// ```swift
    /// func setup() {
    ///     logo = try? loadShape("assets/logo.svg")
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let logo else { return }
    ///     shape(logo, 40, 40)
    ///     push()
    ///     translate(200, 40)
    ///     scale(3, 3)
    ///     shape(logo)
    ///     pop()
    ///     shape(logo, at: [Placement(x: 40, y: 220, fill: color(255, 140, 60))])
    /// }
    /// ```
    ///
    /// Illustrator や Figma で描いたロゴや図案を、**画素ではなく形として**読む。画像に焼いて
    /// ``loadImage(_:)`` で貼ると、拡大すれば粗くなり、色も変えられない。読んだ形は
    /// ``createShape(_:)`` で組み立てた形と同じもので、同じ口で置く。
    ///
    /// - **位置**: ``shape(_:_:_:)`` に渡した位置が、SVG の原点 (`viewBox` の左上) になる
    /// - **大きさ**: SVG の 1 単位 (`px`) が 1 画素。`width` / `height` と `viewBox` が
    ///   書いてあれば、その大きさへ写した形になる。変えるには ``scale(_:_:)`` か
    ///   ``Placement/scale``。**拡大しても滑らかに出る** — 矩形・円・楕円は距離関数で描き、
    ///   曲線は 20 倍に拡大しても折れ目が見えない細かさで刻む
    /// - **色**: SVG に書いた塗りと線の色が形に焼き付く (``createShape(_:)`` と同じ)。
    ///   置く前の ``fill(_:)`` は効かない。置き場所ごとに変えるなら ``Placement/fill`` で
    ///   **色を掛ける**。色を丸ごと差し替えたいなら、白で描いた SVG を読んで掛ける色を渡す —
    ///   白に掛けた色はそのまま出る
    ///
    /// 呼んだときの描き方 (``fill(_:)``・``blendMode(_:)``・``shader(_:)``・``texture(_:)-(Image)`` など)
    /// には左右されない。同じファイルからは、いつ読んでも同じ形ができる。
    ///
    /// ## 読むもの
    ///
    /// - 形: `path` (`d` の命令すべて — 相対の座標・省略した書き方・弧を含む)・`rect`
    ///   (角丸を含む)・`circle`・`ellipse`・`line`・`polyline`・`polygon`
    /// - 入れ物: `g`・`a`・入れ子の `svg`・`switch` (拡張を求めない最初の子)。`transform`
    ///   (`matrix` / `translate` / `scale` / `rotate` / `skewX` / `skewY`)・`viewBox`・
    ///   `preserveAspectRatio` が効く
    /// - 塗りと線: 色 (`#rgb` / `#rrggbb` と不透明度つきの形・`rgb()` / `rgba()`・名前の色・
    ///   `currentColor`)・`fill-opacity` / `stroke-opacity` / `opacity`・`stroke-width`・
    ///   `stroke-linecap`・`stroke-linejoin`・`fill-rule`
    /// - 書き方: 属性・`style` 属性・`<style>` の規則 (クラス 1 つか要素名 1 つのセレクタ。
    ///   Illustrator の書き出しの既定がこの形)
    ///
    /// ## 描けないものは捨てて、知らせる
    ///
    /// 字 (`text`)・画像 (`image`)・`use`・グラデーションやパターンの塗り (`url(#…)`)・
    /// 切り抜き (`clip-path`)・`mask`・`filter`・矢じり (`marker`)・破線 (`stroke-dasharray`)・
    /// アニメーション、読めない値と CSS の規則は描かない。**捨てたものは、そのファイルにつき
    /// 1 度、何を何回・最初に出た行を添えて知らせる。** 描ける部分は描く — 字が 1 つ混ざって
    /// いるだけで、ロゴ全体が読めなくなることはない。塗りが `url(#a) red` のように代わりの色を
    /// 持っていれば、その色で塗る。
    ///
    /// 描くものが 1 つも無いファイルは空の形 (``Shape/isEmpty``) になり、同じく知らせる。
    ///
    /// SVG と見え方が違う所:
    ///
    /// - 群に掛けた `opacity` は、子の色ひとつずつに掛ける。子どうしが重なった所は SVG より濃く出る
    /// - `fill-rule="evenodd"` は、交わらない輪郭どうしなら SVG と同じに塗る。交わる輪郭は回り数で塗る
    /// - 尖った角が切られる長さは ``StrokeJoin/miter`` のもので、`stroke-miterlimit` は読まない
    ///
    /// ## 読めないときは投げる
    ///
    /// 読めなかったときに別の道を選ぶ判断が要るので、黙って空の形へ倒さない。
    ///
    /// - ファイルが見つからない: ``DataFailure/notFound(path:searched:)`` (探した場所が載る)
    /// - UTF-8 の文字として読めない: ``DataFailure/unreadable(path:)``
    /// - XML として壊れている・根が `<svg>` でない: ``DataFailure/malformed(path:line:reason:)``
    ///   (壊れていた行が載る)
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。URL からは読まない。
    ///
    /// **形を記録する面が要るので、`setup()` か ``draw()`` の中で呼ぶ。** 同じ名前を読み直すと、
    /// ファイルをもう一度読む。毎フレーム呼ばず、`setup()` で読んで持ち回る。
    ///
    /// - Throws: 上のどれか (``DataFailure``)。
    // shot: 撮れない 読む先の SVG のファイルが要るが、このリポジトリは SVG のファイルを持たない
    public func loadShape(_ path: String) throws(DataFailure) -> Shape {
        let url = try dataURL(path)
        let drawing = try SVGFile.parse(try TextFile.read(url, path: path), path: path)
        return canvas.shape(of: drawing, readFrom: path)
    }

    /// SVG のファイルを読み、保持した形にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var logo: Shape? -->
    /// ```swift
    /// func setup() {
    ///     Task { logo = try? await requestShape("assets/logo.svg") }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     if let logo { shape(logo, 40, 40) }
    /// }
    /// ```
    ///
    /// ファイルを読んで解く仕事を別の仕事として回すので、大きな SVG を読んでもフレームが詰まらない。
    /// 形にするのは届いた後、フレームとフレームの間である。読み方・知らせ方・失敗は
    /// ``loadShape(_:)`` と同じ。
    ///
    /// 呼び方と届く前の扱いは ``requestImage(_:)`` と同じで、**`setup()` の中で `Task` を起こし、
    /// そこから呼ぶ。** 届くまでの ``draw()`` は形が無いまま呼ばれ、置くのは `draw()` の中である。
    ///
    /// - Throws: ``loadShape(_:)`` と同じ (``DataFailure``)。
    // shot: 撮れない 読む先の SVG のファイルが要るが、このリポジトリは SVG のファイルを持たない
    public func requestShape(_ path: String) async throws(DataFailure) -> Shape {
        let surface = Self.requireLoadingCanvas("requestShape(_:)")
        let url = try dataURL(path)
        let drawing = try await Self.readAway { () throws(DataFailure) in
            try SVGFile.parse(try TextFile.read(url, path: path), path: path)
        }
        return surface.shape(of: drawing, readFrom: path)
    }
}
