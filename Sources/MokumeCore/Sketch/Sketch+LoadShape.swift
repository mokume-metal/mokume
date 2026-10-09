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
    /// 下の 4 枚は、例がその場で書き出した SVG — 80×50 の `viewBox` に、橙の正方形と水色の円を
    /// 1 つずつ描いたもの — を読んで置いたもので、1 枚ごとに SVG の中身か置き方を 1 か所だけ
    /// 変えてある。このリポジトリは SVG のファイルを持たないので、読む先は例が自分で作っている。
    ///
    /// まず等倍で 2 か所に置く。白い点が、``shape(_:_:_:)`` に渡した位置である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var mark: Shape? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         let svg = """
    ///             <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 50">
    ///               <rect x="0" y="0" width="50" height="50" fill="#f27340"/>
    ///               <circle cx="65" cy="15" r="15" fill="#59c2e6"/>
    ///             </svg>
    ///             """
    ///         let path = NSTemporaryDirectory() + "mark.svg"
    ///         try? svg.write(toFile: path, atomically: true, encoding: .utf8)
    ///         mark = try? loadShape(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let mark else { return }
    ///         shape(mark, 40, 40)
    ///         shape(mark, 220, 150)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(40, 40, 8)
    ///         circle(220, 150, 8)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙の正方形と水色の円の図案が、等倍で 2 か所に置かれている。どちらも白い点 (置いた位置) が図案の左上の角に来る -->
    ///     ![橙の正方形と水色の円の図案が、等倍で 2 か所に置かれている。どちらも白い点 (置いた位置) が図案の左上の角に来る](https://i.gyazo.com/a7d69881928db10e8d13184bc1a69b56.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// SVG の `width` と `height` を `viewBox` の 2 倍にすると、同じ図案が 2 倍の大きさで置かれる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var mark: Shape? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         let svg = """
    ///             <svg xmlns="http://www.w3.org/2000/svg" width="160" height="100" viewBox="0 0 80 50">
    ///               <rect x="0" y="0" width="50" height="50" fill="#f27340"/>
    ///               <circle cx="65" cy="15" r="15" fill="#59c2e6"/>
    ///             </svg>
    ///             """
    ///         let path = NSTemporaryDirectory() + "mark-160x100.svg"
    ///         try? svg.write(toFile: path, atomically: true, encoding: .utf8)
    ///         mark = try? loadShape(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let mark else { return }
    ///         shape(mark, 40, 40)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(40, 40, 8)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: width と height を viewBox の 2 倍にした SVG は、同じ図案が縦横 2 倍で置かれる。白い点 (置いた位置) は左上の角のまま -->
    ///     ![width と height を viewBox の 2 倍にした SVG は、同じ図案が縦横 2 倍で置かれる。白い点 (置いた位置) は左上の角のまま](https://i.gyazo.com/dadd62bdbc531b3d34c4415d648ae0f6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ``scale(_:_:)`` で 3 倍にしても、縁は粗くならない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var mark: Shape? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         let svg = """
    ///             <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 50">
    ///               <rect x="0" y="0" width="50" height="50" fill="#f27340"/>
    ///               <circle cx="65" cy="15" r="15" fill="#59c2e6"/>
    ///             </svg>
    ///             """
    ///         let path = NSTemporaryDirectory() + "mark.svg"
    ///         try? svg.write(toFile: path, atomically: true, encoding: .utf8)
    ///         mark = try? loadShape(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let mark else { return }
    ///         push()
    ///         translate(40, 40)
    ///         scale(3, 3)
    ///         shape(mark)
    ///         pop()
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: scale(3, 3) で 3 倍に置いた図案。円の縁は、同じ大きさで circle() を描いたときと同じく滑らか -->
    ///     ![scale(3, 3) で 3 倍に置いた図案。円の縁は、同じ大きさで circle() を描いたときと同じく滑らか](https://i.gyazo.com/eb6b95f5b69a4b76cf50a85e90fd0b1f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 白で描いた SVG なら、置き場所ごとに色を渡して染められる。置く前の ``fill(_:)`` は効かない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var mark: Shape? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         let svg = """
    ///             <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 50">
    ///               <rect x="0" y="0" width="50" height="50" fill="white"/>
    ///               <circle cx="65" cy="15" r="15" fill="white"/>
    ///             </svg>
    ///             """
    ///         let path = NSTemporaryDirectory() + "mark-white.svg"
    ///         try? svg.write(toFile: path, atomically: true, encoding: .utf8)
    ///         mark = try? loadShape(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let mark else { return }
    ///         fill(242, 115, 64)              // 置く側の塗り。図案の色には効かない
    ///         shape(mark, at: [Placement(x: 40, y: 100, scale: 2)])
    ///         shape(mark, at: [Placement(x: 220, y: 100, scale: 2, fill: color(242, 115, 64))])
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白で描いた図案が 2 つ。左は置く前に fill で橙を選んでも白のまま、右は置き場所に橙を渡したので、正方形も円も橙に染まる -->
    ///     ![白で描いた図案が 2 つ。左は置く前に fill で橙を選んでも白のまま、右は置き場所に橙を渡したので、正方形も円も橙に染まる](https://i.gyazo.com/53b595fc4a7f9c2072d57df4dbfcf724.png)
    ///     <!-- /shot -->
    ///   }
    /// }
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
    // shot: 1 snippet=002b4165
    // shot: 2 snippet=bbba0594
    // shot: 3 snippet=b33c97d0
    // shot: 4 snippet=8ae46fb2
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
    /// > Note: 届いた形の見え方は ``loadShape(_:)`` と同じなので、絵はそちらを見ること。
    /// > 何枚目のフレームで届くかは SVG の大きさとフレームの間隔で変わり、同じ条件でも実行ごとに
    /// > ずれうるので、この口だけの絵は撮っていない。
    ///
    /// - Throws: ``loadShape(_:)`` と同じ (``DataFailure``)。
    // shot: 参照 loadShape(_:)
    public func requestShape(_ path: String) async throws(DataFailure) -> Shape {
        let surface = Self.requireLoadingCanvas("requestShape(_:)")
        let url = try dataURL(path)
        let drawing = try await Self.readAway { () throws(DataFailure) in
            try SVGFile.parse(try TextFile.read(url, path: path), path: path)
        }
        return surface.shape(of: drawing, readFrom: path)
    }
}
