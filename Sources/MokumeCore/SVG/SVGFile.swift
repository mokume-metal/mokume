// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// SVG の文字を、形として置ける線と色の並びへ読み解く。
///
/// ## 読んだものは本体の図形の口で置く
///
/// ここが作るのは**線と色の並び** (``Drawing``) までで、絵にはしない。並びは置く側
/// (``Canvas``) が `createShape { }` の中で `beginShape` / `vertex` / `bezierVertex` /
/// `rect` / `ellipse` / `line` と `fill` / `stroke` を呼んで形にする。読んだ SVG だけが
/// 通る描き方を作らないので、色の扱い・変換・書き出しは手で描いた図形とまったく同じに効く。
///
/// ## 読むもの
///
/// - 形: `path` (`d` の文法のすべて)・`rect` (角丸を含む)・`circle`・`ellipse`・`line`・
///   `polyline`・`polygon`
/// - 入れ物: `g`・`a`・入れ子の `svg` (`viewBox` と `preserveAspectRatio`)・`switch`
///   (拡張を求めない最初の子だけ)
/// - `transform` (`matrix` / `translate` / `scale` / `rotate` / `skewX` / `skewY`)
/// - 塗りと線: 色・`currentColor`・`fill-opacity` / `stroke-opacity` / `opacity`・
///   `stroke-width`・`stroke-linecap`・`stroke-linejoin`・`fill-rule`
/// - 書き方: 属性・`style` 属性・`<style>` の `*` か要素名 1 つかクラス 1 つのセレクタ。優先の順は
///   CSS のとおり (属性 < `*` の規則 < 要素名の規則 < クラスの規則 < `style` 属性。`!important` を
///   付けた宣言はそれらすべてより上で、その中でも同じ順)
///
/// ## 描けないものは捨てて、何を捨てたかを残す
///
/// 字・画像・`use`・グラデーションやパターンの塗り (`url(#…)`)・切り抜き・マスク・
/// フィルタ・矢じり・破線・アニメーション、読めない値と CSS の規則は描かない。**黙って
/// 捨てず**、何を何個・最初に出た行を ``Drawing/skipped`` に残す ([ADR-0020] 決定 5)。
/// 描かないことが書き手の意図であるもの (`display="none"`・`defs` の中の定義・`title` /
/// `desc` / `metadata`・他の名前空間の要素) は数えない。
///
/// **ファイルとして読めないものは投げる** — XML として壊れている・根が `<svg>` でない
/// (``DataFailure/malformed(path:line:reason:)``)。読めたファイルの中の描けない要素では
/// 投げない。描ける部分まで捨てると、1 つの字のためにロゴ全体が読めなくなる
/// (``ModelFile`` が読めない行で止まらないのと同じ理由)。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読み解きを別の仕事として回すため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
nonisolated enum SVGFile {
    /// 読み解いた中身。
    struct Drawing: Sendable, Equatable {
        /// 描くもの。書かれた順 (後のものほど上に重なる)。
        var items: [Item]
        /// 描かずに捨てたもの。最初に出た順。
        var skipped: [Skip]
        /// **描いているが、SVG と見え方が違う**ものの名乗り。最初に出た順。群や、塗りと線を両方持つ
        /// 要素の `opacity` を子の色ごとに掛けるので、重なった所が SVG より濃く出る (#2884)。
        /// ``skipped`` には混ぜない — 捨てたのではなく、近似で描いている。
        ///
        /// **つなぎの欄である。** 層の `opacity` を本体が持ち、群をそれで描くようになれば ([#2878]) 、
        /// この欄と名乗りごと消える。
        ///
        /// [#2878]: https://github.com/mokume-metal/mokume/issues/2878
        var approximated: [Skip] = []
    }

    /// 近似の名乗りの種類 (``Drawing/approximated`` の ``Skip/what``)。
    static let groupOpacityNote = "opacity on a group whose shapes overlap"
    static let fillAndStrokeOpacityNote = "opacity on a shape with both fill and stroke"

    /// 描かずに捨てたものの 1 種類。
    struct Skip: Sendable, Equatable {
        /// 何を捨てたか (`<text>`・`fill="url(…)"`・`clip-path` など)。
        var what: String
        /// 何回出たか。
        var count: Int
        /// 最初に出た行 (1 から数える)。
        var line: Int
    }

    /// 描くもの 1 つ。
    struct Item: Sendable, Equatable {
        var outline: Outline
        /// 塗り。`nil` なら塗らない。不透明度 (`fill-opacity` と `opacity`) は掛けてある。
        var fill: Color?
        var fillRule: FillRule
        /// 線。`nil` なら引かない。
        var stroke: Color?
        /// 線の太さ (この要素の座標の単位)。
        var strokeWidth: Float
        var cap: StrokeCap
        var join: StrokeJoin
        /// この要素の座標から形の座標への変換 (祖先の `transform` と `viewBox` を畳んだもの)。
        var transform: Affine
    }

    /// 塗りの規則。
    enum FillRule: Sendable, Equatable {
        case nonzero
        case evenOdd
    }

    /// 形の輪郭。
    enum Outline: Sendable, Equatable {
        /// 直線と 3 次曲線の線の集まり。
        case path([Subpath])
        /// 角の丸くない矩形 (左上と大きさ)。
        case rect(x: Float, y: Float, width: Float, height: Float)
        /// 楕円 (中心と半径)。
        case ellipse(centerX: Float, centerY: Float, radiusX: Float, radiusY: Float)
        /// 直線 1 本。**塗らない** (SVG の `line` は塗りを持たない)。
        case line(from: SIMD2<Float>, to: SIMD2<Float>)
    }

    // MARK: - 読み解く

    /// SVG の文字を読み解く。
    ///
    /// - Parameter path: 失敗を名乗るための名前。
    static func parse(_ text: String, path: String) throws(DataFailure) -> Drawing {
        let reader = Reader()
        // 渡すバイトは ``XMLFile`` と同じに整える (XML 宣言の `encoding` を読まず、行の終わりを揃える)
        let parser = XMLParser(data: XMLFile.document(of: text))
        parser.delegate = reader
        // XML の中の名前から、手元のファイルや外の URL を読みに行かない (``XMLFile`` と同じ約束)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let succeeded = parser.parse()
        guard succeeded, !reader.failed, case .start(let rootName, _, let rootLine)? = reader.events.first
        else {
            // 壊れ方の言い方 (行と理由) は ``XMLFile`` が持つので、そちらに読み直させる。壊れて
            // いないファイルはここへ来ないので、読み直すのは壊れたファイルのときだけである
            _ = try XMLFile.parse(text, path: path)
            throw .malformed(path: path, line: 1, reason: "the XML could not be read")
        }
        // 根に前置き (`s:svg`) があれば、SVG の要素は同じ前置きで書かれている
        let parts = rootName.split(separator: ":")
        let prefix = parts.count == 2 ? "\(parts[0]):" : ""
        guard rootName.dropFirst(prefix.count) == "svg" else {
            throw .malformed(
                path: path, line: rootLine,
                reason: "the root element is <\(rootName)>, not <svg>. Only SVG can be read as a shape")
        }
        var walk = Walk(prefix: prefix)
        for style in reader.styles { walk.read(styleSheet: style.text, line: style.line) }
        for event in reader.events { walk.visit(event) }
        return Drawing(items: walk.items, skipped: walk.tally.skips, approximated: walk.approximations.skips)
    }

    /// 要素の名前のうち、描かずに捨てて**名乗る**もの。
    private static let reportedElements: Set<String> = [
        "text", "image", "use", "foreignObject", "video", "audio", "iframe", "canvas", "animate",
        "animateMotion", "animateTransform", "animateColor", "set", "discard",
    ]

    /// 要素の名前のうち、描かないことが書き手の意図で、**数えない**もの。中身も描かない。
    private static let silentElements: Set<String> = [
        "defs", "symbol", "clipPath", "mask", "pattern", "marker", "linearGradient",
        "radialGradient", "meshgradient", "hatch", "filter", "title", "desc", "metadata", "script",
        "style", "font", "font-face", "view", "cursor", "color-profile",
    ]

    /// アニメーションの要素。形の中に書かれていても名乗る。
    private static let animationElements: Set<String> = [
        "animate", "animateMotion", "animateTransform", "animateColor", "set",
    ]

    // MARK: - XML を読む

    /// XML の知らせ 1 つ。
    enum Event {
        case start(name: String, attributes: [String: String], line: Int)
        case end
    }

    /// `XMLParser` から届く知らせを、開始と終了の並びとして控える。**木にしない** — 並びのまま
    /// 積み上げで辿るので、入れ子が深くても呼び出しが重ならない (``XMLFile`` が木の深さに
    /// 上限を置いている理由が、ここには無い)。
    private nonisolated final class Reader: NSObject, XMLParserDelegate {
        var events: [Event] = []
        /// `<style>` に書かれた文字と、その要素の行。
        var styles: [(text: String, line: Int)] = []
        var failed = false
        /// いま `<style>` の中にいれば、その文字を溜める先の番号。
        private var openStyle: Int?
        private var depth = 0
        private var styleDepth = 0

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            events.append(.start(name: elementName, attributes: attributeDict, line: parser.lineNumber))
            if openStyle == nil, elementName == "style" || elementName.hasSuffix(":style") {
                styles.append(("", parser.lineNumber))
                openStyle = styles.count - 1
                styleDepth = depth
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if openStyle != nil, depth == styleDepth { openStyle = nil }
            depth -= 1
            events.append(.end)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let index = openStyle else { return }
            styles[index].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let index = openStyle else { return }
            styles[index].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            failed = true
        }
    }

    // MARK: - 辿る

    /// 描かずに捨てたものを数える。
    struct Tally {
        private(set) var skips: [Skip] = []
        private var index: [String: Int] = [:]

        mutating func note(_ what: String, line: Int) {
            if let at = index[what] {
                skips[at].count += 1
            } else {
                index[what] = skips.count
                skips.append(Skip(what: what, count: 1, line: line))
            }
        }
    }

    /// 祖先から受け継ぐ描き方と、座標の決まり。
    private struct Context {
        var fill = Paint.color(.black)
        /// 塗りが `url(#…)` を指していたか (描けないので、描いた要素ごとに名乗る)。
        var fillIsReference = false
        var fillOpacity: Float = 1
        var fillRule = FillRule.nonzero
        var stroke = Paint.none
        var strokeIsReference = false
        var strokeOpacity: Float = 1
        var strokeWidth: Float = 1
        /// SVG の既定の端は `butt` (長さちょうどで切る) で、本体の綴りでは ``StrokeCap/square``。
        var cap = StrokeCap.square
        var join = StrokeJoin.miter
        var color = Color.black
        var isVisible = true
        /// 破線が指定されているか。**描けないので、線を引いた要素ごとに名乗る**。
        var isDashed = false
        /// 祖先と自分の `opacity` を掛けたもの。
        var opacity: Float = 1
        var transform = Affine.identity
        /// 割合 (`%`) の基準になる大きさ (いちばん近い `svg` の `viewBox`)。
        var viewport = SIMD2<Float>(100, 100)
        /// この要素自身の受け継がない描き方。子へは受け継がず、子の `inherit` だけが親の値として取る。
        var own = Own()

        /// 割合で書いた半径などの基準 (対角線の長さを √2 で割ったもの)。
        var diagonal: Float { ((viewport.x * viewport.x + viewport.y * viewport.y) / 2).squareRoot() }
    }

    /// 受け継がない描き方。要素ごとに初めの値から始まり、勝った宣言が `inherit` のときだけ親の値を取る (CSS のとおり)。
    private struct Own {
        /// 要素自身の `opacity` (祖先の分は掛けていない)。
        var opacity: Float = 1
        var isDisplayed = true
        /// 描けない効果 (`clip-path` など) を持つ性質の名前。`marker` は `marker-start` / `marker-mid` /
        /// `marker-end` に分けて持つ。
        var effects: Set<String> = []

        /// 描けないので名乗るもの。決まった順 (`clip-path`・`mask`・`filter`・`marker`・`mix-blend-mode`)。
        var lost: [String] {
            var names = ["clip-path", "mask", "filter"].filter(effects.contains)
            if !effects.isDisjoint(with: SVGFile.markerLonghands) { names.append("marker") }
            if effects.contains("mix-blend-mode") { names.append("mix-blend-mode") }
            return names
        }

        /// 受け継がない性質 1 つを親の値にする。受け継ぐ性質 (`fill` など) では何もしない — 受け継いだ値が
        /// そのまま親の値である。
        mutating func inherit(_ property: String, from parent: Own) {
            switch property {
            case "opacity": opacity = parent.opacity
            case "display": isDisplayed = parent.isDisplayed
            case _ where SVGFile.effectProperties.contains(property):
                if parent.effects.contains(property) { effects.insert(property) }
            default: break
            }
        }
    }

    /// 開いている要素 1 つ。
    private struct Frame {
        enum Mode {
            /// 子を描く。
            case render
            /// `switch`。子のうち最初に選べたものだけを描く。
            case choose
            /// 子を描かない。数えもしない。
            case inert
            /// 形の中。アニメーションだけを名乗り、ほかは読まない。
            case shape
        }

        var context: Context
        var mode: Mode
        /// `switch` が子を選び終えたか。
        var chose = false
        /// この要素が `opacity` < 1 の容器なら、``Walk/groups`` の中の番号 (#2884)。
        var group: Int?
    }

    /// 外接矩形 (形の座標)。``Drawing/approximated`` の重なりの判定にだけ使う。
    struct Box {
        var low: SIMD2<Float>
        var high: SIMD2<Float>

        init(low: SIMD2<Float>, high: SIMD2<Float>) {
            self.low = low
            self.high = high
        }

        init(points: [SIMD2<Float>]) {
            var low = points[0]
            var high = points[0]
            for point in points.dropFirst() {
                low = pointwiseMin(low, point)
                high = pointwiseMax(high, point)
            }
            self.init(low: low, high: high)
        }

        func expanded(by amount: Float) -> Box { Box(low: low - amount, high: high + amount) }

        /// 面積のある重なりがあるか (辺が接するだけなら重ならない)。
        func overlaps(_ other: Box) -> Bool {
            low.x < other.high.x && other.low.x < high.x && low.y < other.high.y && other.low.y < high.y
        }
    }

    /// `opacity` < 1 の容器 1 つ。描くものの外接矩形を集め、重なりを見つけたら 1 度だけ名乗る。
    struct OpacityGroup {
        var line: Int
        var boxes: [Box] = []
        var named = false
    }

    /// 並びを前から辿り、描くものと捨てたものを集める。
    private struct Walk {
        let prefix: String
        var items: [Item] = []
        var tally = Tally()
        /// 描いているが SVG と見え方が違うもの (``Drawing/approximated``)。
        var approximations = Tally()
        /// `opacity` < 1 の容器 (開いたものの順)。
        private var groups: [OpacityGroup] = []
        private var rules: [StyleRule] = []
        private var stack: [Frame] = []

        init(prefix: String) { self.prefix = prefix }

        mutating func read(styleSheet text: String, line: Int) {
            let sheet = SVGFile.parseStyleSheet(text)
            rules += sheet.rules
            for selector in sheet.unread { tally.note("CSS rule \"\(selector)\"", line: line) }
            for written in sheet.unreadDeclarations { tally.note("CSS declaration \"\(written)\"", line: line) }
        }

        mutating func visit(_ event: Event) {
            switch event {
            case .end:
                _ = stack.popLast()
            case .start(let rawName, let attributes, let line):
                start(rawName, attributes, line)
            }
        }

        /// SVG の名前空間の要素なら、前置きを外した名前。他の名前空間の要素なら `nil`。
        private func localName(_ raw: String) -> String? {
            if !prefix.isEmpty, raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
            return raw.contains(":") ? nil : raw
        }

        private mutating func start(_ rawName: String, _ attributes: [String: String], _ line: Int) {
            let parent = stack.last ?? Frame(context: Context(), mode: .render)
            func push(_ mode: Frame.Mode, _ context: Context? = nil) {
                stack.append(Frame(context: context ?? parent.context, mode: mode))
            }
            // 半透明の容器は、描くものの重なりを見るために登録する (#2884)
            func pushContainer(_ mode: Frame.Mode, _ context: Context) {
                var frame = Frame(context: context, mode: mode)
                if context.own.opacity < 1 {
                    groups.append(OpacityGroup(line: line))
                    frame.group = groups.count - 1
                }
                stack.append(frame)
            }
            guard let name = localName(rawName) else { return push(.inert) }
            switch parent.mode {
            case .inert:
                return push(.inert)
            case .shape:
                if SVGFile.animationElements.contains(name) { tally.note("<\(name)>", line: line) }
                return push(.inert)
            case .choose:
                // 拡張や言語を求める子は選ばない (この読み手はどの拡張も持たない)
                let acceptable =
                    !parent.chose && name != "foreignObject" && attributes["requiredExtensions"] == nil
                    && attributes["systemLanguage"] == nil
                guard acceptable else { return push(.inert) }
                stack[stack.count - 1].chose = true
            case .render:
                break
            }

            if SVGFile.silentElements.contains(name) { return push(.inert) }
            guard let (resolved, lost, sizes) = resolve(parent.context, attributes: attributes, name: name, line: line)
            else { return push(.inert) }
            var context = resolved
            if SVGFile.reportedElements.contains(name) {
                tally.note("<\(name)>", line: line)
                return push(.inert)
            }
            for what in lost { tally.note(what, line: line) }
            switch name {
            case "svg":
                guard
                    let viewport = viewport(
                        of: attributes, sizes: sizes, in: context, isRoot: stack.isEmpty, line: line)
                else { return push(.inert) }
                context.transform = context.transform * viewport.transform
                context.viewport = viewport.size
                pushContainer(.render, context)
            case "g", "a":
                context.transform = context.transform * ownTransform(attributes, line: line)
                pushContainer(.render, context)
            case "switch":
                context.transform = context.transform * ownTransform(attributes, line: line)
                pushContainer(.choose, context)
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                context.transform = context.transform * ownTransform(attributes, line: line)
                if context.isVisible, let outline = outline(name, attributes, context, line: line) {
                    add(outline, context, line: line)
                }
                push(.shape, context)
            default:
                tally.note("<\(name)>", line: line)
                push(.inert)
            }
        }

        // MARK: 描き方を決める

        /// 受け継いだ描き方に、属性・CSS の規則・`style` 属性の宣言を重ねる。重ね方は CSS のとおり
        /// 1 つの比べ方 (`Rank`) で、`!important` の宣言が上、次に 属性 < 規則 < `style` 属性、規則どうしは
        /// 詳細度 (`*` < 要素名 < クラス)、それも同じなら後に書いたほうが上。
        /// **性質ごとに、読める宣言のうち順位が最も高い 1 つだけを当てる** (勝った宣言だけが効き、負けた
        /// 宣言の値は残らない)。読めない値の宣言は名乗って無かったことにする (下の宣言が残る)。勝った宣言が
        /// `none` なら効果は無く、`inherit` なら親の値になる (受け継がない `opacity`・`display`・描けない
        /// 効果も、親の値を取る)。`marker` は `marker-start` / `marker-mid` / `marker-end` の短縮形として重ねる。
        /// **`display` が `none` に決まれば `nil`** (中身ごと描かない。書き手の意図なので、この要素の読めない
        /// 値も名乗らない)。
        /// 描けない効果 (`clip-path` など) は、要素を描くと決まってから名乗れるよう返す。
        /// **`svg` の `width` / `height` は、属性と CSS (`<style>`・`style` 属性) の宣言を同じ順位で重ねて**、
        /// 順位の低いほうから並べた文字を `sizes` に返す (SVG 2 では CSS の性質でもあるので、CSS で書いた
        /// 根の大きさも効く)。どれを採るかは `viewport` が、読めるかどうかを見て決める。
        private mutating func resolve(
            _ inherited: Context, attributes: [String: String], name: String, line: Int
        ) -> (Context, lost: [String], sizes: [String: [String]])? {
            var candidates: [(rank: Rank, declaration: Declaration)] = []
            func collect(_ declaration: Declaration, from origin: Rank.Origin, specificity: Int = 0) {
                let rank = Rank(
                    isImportant: declaration.isImportant, origin: origin, specificity: specificity,
                    order: candidates.count)
                candidates.append((rank, declaration))
            }
            // 名乗るものは、要素を描くと決まるまで溜める
            var unreadable: [String] = []
            // 属性の書いた順は分からない (`XMLParser` が辞書で渡す) ので、決まった順で集める — 辞書の巡る順は
            // プロセスごとに変わる。順が効くのは短縮形の `marker` と個別の `marker-*` の重なりだけで、短縮形を先に
            // 置いて個別の性質を勝たせる (CSS で短縮形を先に書いたのと同じ)。ほかは名前の順
            func place(_ property: String) -> (Int, String) { (property == "marker" ? 0 : 1, property) }
            let written = attributes.sorted { place($0.key) < place($1.key) }
            for (property, value) in written
            where SVGFile.properties.contains(property) || (name == "svg" && SVGFile.sizeProperties.contains(property))
            {
                collect(Declaration(name: property, value: value, isImportant: false), from: .attribute)
            }
            let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            for rule in rules where rule.selector.matches(name: name, classes: classes) {
                for declaration in rule.declarations {
                    collect(declaration, from: .rule, specificity: rule.selector.specificity)
                }
            }
            if let style = attributes["style"] {
                let parsed = SVGFile.parseDeclarations(style)
                for declaration in parsed.declarations { collect(declaration, from: .styleAttribute) }
                unreadable += parsed.unreadable.map { "CSS declaration \"\($0)\"" }
            }

            // 順位の低いほうから見て、性質ごとに読めた宣言で上書きしていく。最後に残るのが勝った宣言
            var winners: [String: Reading] = [:]
            var sizes: [String: [String]] = [:]
            for (_, declaration) in candidates.sorted(by: { $0.rank < $1.rank }) {
                let property = declaration.name
                let value = declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if SVGFile.sizeProperties.contains(property) {
                    if value.lowercased() != "inherit" { sizes[property, default: []].append(value) }
                    continue
                }
                guard SVGFile.properties.contains(property) else { continue }
                let reading = read(property, value, in: inherited)
                if case .unreadable = reading {
                    unreadable.append("\(property) \"\(value)\"")
                    continue
                }
                for longhand in property == "marker" ? SVGFile.markerLonghands : [property] {
                    winners[longhand] = reading
                }
            }

            var context = inherited
            var own = Own()
            for (property, reading) in winners {
                switch reading {
                case .inherit: own.inherit(property, from: inherited.own)
                case .set(let assign): assign(&context, &own)
                case .effect(let present): if present { own.effects.insert(property) }
                case .unreadable: break
                }
            }
            guard own.isDisplayed else { return nil }
            for what in unreadable { tally.note(what, line: line) }
            context.opacity *= own.opacity
            context.own = own
            return (context, own.lost, sizes)
        }

        /// 宣言 1 つの値の読み。**読むだけで、名乗りも当てもしない** (どの宣言が勝つかは `resolve` が決める)。
        private enum Reading {
            /// 親の値を取る (`inherit`。`color` では `currentColor` も)。
            case inherit
            /// 読めない値。CSS で読めない宣言が無かったことになるのと同じく、下の宣言・受け継いだ値が残る。
            case unreadable
            /// 描き方を書き換える。
            case set((inout Context, inout Own) -> Void)
            /// 描けない効果 (`clip-path` など) を持つか。`none` (`mix-blend-mode` は `normal`) なら持たない。
            case effect(Bool)
        }

        /// 宣言 1 つの値を読む。`value` は前後の空白を落としたもの。大文字と小文字は区別しない。
        private func read(_ property: String, _ value: String, in inherited: Context) -> Reading {
            let lowered = value.lowercased()
            guard lowered != "inherit" else { return .inherit }
            switch property {
            case "fill", "stroke":
                let isFill = property == "fill"
                let paint: Paint
                var isReference = false
                switch SVGFile.parsePaint(value) {
                case .paint(let read): paint = read
                case .inherit: return .inherit
                case .reference(let fallback):
                    paint = fallback
                    isReference = true
                // 代わりの色が読めない参照 (`url(#a) abc`) もここで、下の宣言・受け継いだ値が残る (#2649)
                case .unreadable: return .unreadable
                }
                return .set { context, _ in
                    if isFill {
                        context.fill = paint
                        context.fillIsReference = isReference
                    } else {
                        context.stroke = paint
                        context.strokeIsReference = isReference
                    }
                }
            case "fill-opacity", "stroke-opacity", "opacity":
                guard let amount = Self.fraction(value) else { return .unreadable }
                switch property {
                case "fill-opacity": return .set { context, _ in context.fillOpacity = amount }
                case "stroke-opacity": return .set { context, _ in context.strokeOpacity = amount }
                default: return .set { _, own in own.opacity = amount }
                }
            case "fill-rule":
                switch lowered {
                case "nonzero": return .set { context, _ in context.fillRule = .nonzero }
                case "evenodd": return .set { context, _ in context.fillRule = .evenOdd }
                default: return .unreadable
                }
            case "stroke-width":
                guard let width = SVGFile.parseLength(value, reference: inherited.diagonal), width >= 0 else {
                    return .unreadable
                }
                return .set { context, _ in context.strokeWidth = width }
            case "stroke-linecap":
                let cap: StrokeCap
                switch lowered {
                case "butt": cap = .square
                case "round": cap = .round
                case "square": cap = .project
                default: return .unreadable
                }
                return .set { context, _ in context.cap = cap }
            case "stroke-linejoin":
                let join: StrokeJoin
                switch lowered {
                case "miter", "miter-clip", "arcs": join = .miter
                case "round": join = .round
                case "bevel": join = .bevel
                default: return .unreadable
                }
                return .set { context, _ in context.join = join }
            case "stroke-dasharray":
                // 読めない値と負の値を含む値は、破線ありへ倒さず無かったものとして名乗る (#2649)。
                // 全部 0 なら破線にならない (SVG の約束)
                guard let lengths = SVGFile.parseDashArray(value, reference: inherited.diagonal) else {
                    return .unreadable
                }
                let isDashed = lengths.contains { $0 > 0 }
                return .set { context, _ in context.isDashed = isDashed }
            case "color":
                // `color` 自身の `currentColor` は `inherit` と同じ (CSS Color)
                guard lowered != "currentcolor" else { return .inherit }
                guard let color = SVGFile.parseColor(value) else { return .unreadable }
                return .set { context, _ in context.color = color }
            case "visibility":
                // `collapse` は SVG では `hidden` と同じ。読めない値は無かったものとして、受け継いだ値のまま (#2626)
                switch lowered {
                case "visible": return .set { context, _ in context.isVisible = true }
                case "hidden", "collapse": return .set { context, _ in context.isVisible = false }
                default: return .unreadable
                }
            case "display":
                // `none` だけが描かない。CSS Display の値の外は無かったものとして、下の宣言のまま (#2650)
                guard let isDisplayed = SVGFile.parseDisplay(value) else { return .unreadable }
                return .set { _, own in own.isDisplayed = isDisplayed }
            case _ where SVGFile.effectProperties.contains(property) || property == "marker":
                // 文法の外の値を「効果あり」へ倒さず、無かったものとして名乗る (#2410)
                guard let present = SVGFile.parseEffect(property, value) else { return .unreadable }
                return .effect(present)
            default:
                // 読む性質 (`properties`) の外は `resolve` が弾くので、ここへは来ない
                return .set { _, _ in }
            }
        }

        /// 0…1 の割合 (数か百分率) を読む。範囲の外は端へ寄せる。
        private static func fraction(_ text: String) -> Float? {
            let value: Float?
            if text.hasSuffix("%") {
                value = DecimalText.spelled(text.dropLast()).map { $0 / 100 }
            } else {
                value = DecimalText.spelled(text)
            }
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 1)
        }

        /// 要素自身の `transform`。読めなければ名乗って、変換が無いものとして読む。
        private mutating func ownTransform(_ attributes: [String: String], line: Int) -> Affine {
            guard let text = attributes["transform"] else { return .identity }
            guard let transform = SVGFile.parseTransform(text) else {
                tally.note("transform \"\(text)\"", line: line)
                return .identity
            }
            return transform
        }

        /// 長さを書いた文字 1 つの読み。
        private enum Written {
            /// 書いていない。
            case absent
            /// `auto` (SVG 2 では書いていないのと同じ)。`initial` と `unset` も、`auto` が初めの値の口
            /// (`width`・`height`・`rx`・`ry`) では同じ。
            case automatic
            /// 読めない値 (`abc`・空・読めない単位)。**名乗り済み**。
            case unreadable
            case value(Float)

            /// 読めた長さ。書いていない・`auto`・読めない値は `nil`。
            var length: Float? {
                if case .value(let length) = self { return length }
                return nil
            }
        }

        /// 長さの値 1 つを読む。**長さを読む口はみなここを通る** — 書いていないことと `auto` (許される口の
        /// み) は名乗らず、ほかの読めない値は `<要素 名前="値">` の形で名乗る (#2556)。
        ///
        /// `namesNegative` を立てた口 (根と入れ子の `svg` の `width` / `height`) は、負の値も同じ形で名乗る
        /// (#2625。負は SVG では誤りで、0 と違って「描かない」という約束が無い)。**値はそのまま返す** —
        /// 描かないかどうかは呼び側が決める。
        private mutating func written(
            _ text: String?, element: String, key: String, reference: Float, allowsAuto: Bool,
            namesNegative: Bool = false, line: Int
        ) -> Written {
            guard let text else { return .absent }
            if allowsAuto,
                ["auto", "initial", "unset"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            {
                return .automatic
            }
            guard let value = SVGFile.parseLength(text, reference: reference) else {
                tally.note("<\(element) \(key)=\"\(text)\">", line: line)
                return .unreadable
            }
            if namesNegative, value < 0 { tally.note("<\(element) \(key)=\"\(text)\">", line: line) }
            return .value(value)
        }

        /// `svg` が作る座標の決まり。幅か高さが 0 以下なら描かない (SVG の約束) ので `nil`。0 は約束どおりなので
        /// 名乗らず、負の値は書き手の誤りなので名乗る (#2625)。
        /// `sizes` は属性と CSS の `width` / `height` の宣言の文字を、順位の低いほうから並べたもの (`resolve` が返す)。
        private mutating func viewport(
            of attributes: [String: String], sizes: [String: [String]], in context: Context, isRoot: Bool,
            line: Int
        ) -> (transform: Affine, size: SIMD2<Float>)? {
            var box: [Float]?
            if let text = attributes["viewBox"] {
                if let numbers = SVGFile.parseNumbers(text), numbers.count == 4, numbers[2] > 0,
                    numbers[3] > 0
                {
                    box = numbers
                } else {
                    tally.note("viewBox \"\(text)\"", line: line)
                }
            }
            // 読めない値は、書いていないもの (`xMidYMid meet`) として写し、名乗る (#2649)
            var aspect = AspectRatio.standard
            if let text = attributes["preserveAspectRatio"] {
                if let read = SVGFile.parseAspectRatio(text) {
                    aspect = read
                } else {
                    tally.note(
                        "preserveAspectRatio \"\(text.trimmingCharacters(in: .whitespacesAndNewlines))\"", line: line)
                }
            }
            // 根の幅と高さの割合は、viewBox (無ければ 100) に対して読む。入れ子は親の座標の決まりに対して
            let reference = isRoot ? SIMD2(box?[2] ?? 100, box?[3] ?? 100) : context.viewport
            // `x` / `y` は `auto` を取らないので、`auto` も読めない値として名乗る
            func position(_ key: String, _ against: Float) -> Float {
                written(attributes[key], element: "svg", key: key, reference: against, allowsAuto: false, line: line)
                    .length ?? 0
            }
            // 順位の高い宣言から見て、**読めた宣言 (`auto` を含む) で止める**。読めない宣言は CSS では無効で
            // 捨てられ、下の宣言が残るので、名乗って次へ進む。全部が読めなければ書いていないのと同じ
            // **負の値は別**: CSS では無効な宣言だが、ここでは読めた値として採り (描かない結果は変えていない)、
            // 名乗りは「捨てた」ではなく「この値で根を描かない」の意味。CSS との仕様差は #2648 に置いてある
            func size(_ key: String, _ against: Float) -> Float? {
                for text in (sizes[key] ?? []).reversed() {
                    switch written(
                        text, element: "svg", key: key, reference: against, allowsAuto: true, namesNegative: true,
                        line: line)
                    {
                    case .value(let length): return length
                    case .automatic: return nil
                    case .absent, .unreadable: continue
                    }
                }
                return nil
            }
            let x = isRoot ? 0 : position("x", reference.x)
            let y = isRoot ? 0 : position("y", reference.y)
            let writtenWidth = size("width", reference.x)
            let writtenHeight = size("height", reference.y)
            // 根の片方だけなら、書いていない側は viewBox の縦横比から決まる (CSS Images 3 の
            // 既定の大きさの決め方。ブラウザの <img>・resvg・librsvg の大きさ) (#2333)。
            // 比を先に取るのは、途中の積 (書いた側 × viewBox の辺) があふれないようにするため。
            // 導いた値が Float に収まらない (無限大・0 へ潰れる) なら導けないものとし、
            // viewBox の大きさに倒す
            func derived(_ written: Float, _ side: Float, _ across: Float) -> Float {
                let value = written * (side / across)
                return value.isFinite && value > 0 ? value : side
            }
            let width: Float
            let height: Float
            switch (writtenWidth, writtenHeight) {
            case (let written?, let other?):
                (width, height) = (written, other)
            case (let written?, nil):
                width = written
                height = isRoot ? box.map { derived(written, $0[3], $0[2]) } ?? 100 : reference.y
            case (nil, let written?):
                width = isRoot ? box.map { derived(written, $0[2], $0[3]) } ?? 100 : reference.x
                height = written
            case (nil, nil):
                (width, height) = isRoot ? (box?[2] ?? 100, box?[3] ?? 100) : (reference.x, reference.y)
            }
            guard width > 0, height > 0 else { return nil }
            var transform = Affine.translate(x, y)
            guard let box else { return (transform, SIMD2(width, height)) }
            transform =
                transform
                * SVGFile.viewBoxTransform(box, width: width, height: height, aspect: aspect)
            return (transform, SIMD2(box[2], box[3]))
        }

        // MARK: 形を作る

        /// 要素の輪郭。描くものが無い (寸法が 0・読めない) なら `nil`。
        private mutating func outline(
            _ name: String, _ attributes: [String: String], _ context: Context, line: Int
        ) -> Outline? {
            var unreadable = false
            // 書いていない・`auto` は `nil` (名乗らない)。読めない値も `nil` だが、名乗り、この要素は描かない
            func optional(_ key: String, _ reference: Float, allowsAuto: Bool = false) -> Float? {
                switch written(
                    attributes[key], element: name, key: key, reference: reference, allowsAuto: allowsAuto,
                    line: line)
                {
                case .value(let length): return length
                case .unreadable:
                    unreadable = true
                    return nil
                case .absent, .automatic: return nil
                }
            }
            func length(_ key: String, _ reference: Float) -> Float { optional(key, reference) ?? 0 }
            let width = context.viewport.x
            let height = context.viewport.y
            let outline: Outline?
            switch name {
            case "path":
                let data = SVGFile.parsePath(attributes["d"] ?? "")
                if let broken = data.brokenAfter {
                    tally.note("path data after \"\(broken)\"", line: line)
                }
                outline = data.subpaths.isEmpty ? nil : .path(data.subpaths)
            case "rect":
                let x = length("x", width)
                let y = length("y", height)
                // `auto` は SVG 2 では 0 (描かない) で、名乗らない (`rx` と同じ)
                let w = optional("width", width, allowsAuto: true) ?? 0
                let h = optional("height", height, allowsAuto: true) ?? 0
                guard !unreadable, w > 0, h > 0 else { return nil }
                // 片方だけ書いた角の半径は、もう片方にも使う。負の値は書いていないものとして読む
                // 書いていない・`auto` は名乗らず、読めない値は名乗って書いていないものとして読む (#2556)
                // 読めない値は、ここでは `unreadable` を立てず (角が丸まらないだけ)、名乗って書いていないものとする
                let rawX = written(
                    attributes["rx"], element: name, key: "rx", reference: width, allowsAuto: true, line: line
                ).length.flatMap { $0 >= 0 ? $0 : nil }
                let rawY = written(
                    attributes["ry"], element: name, key: "ry", reference: height, allowsAuto: true, line: line
                ).length.flatMap { $0 >= 0 ? $0 : nil }
                let rx = min(rawX ?? rawY ?? 0, w / 2)
                let ry = min(rawY ?? rawX ?? 0, h / 2)
                outline =
                    rx > 0 && ry > 0
                    ? .path([SVGFile.roundedRect(x: x, y: y, width: w, height: h, rx: rx, ry: ry)])
                    : .rect(x: x, y: y, width: w, height: h)
            case "circle":
                let cx = length("cx", width)
                let cy = length("cy", height)
                let r = length("r", context.diagonal)
                guard !unreadable, r > 0 else { return nil }
                outline = .ellipse(centerX: cx, centerY: cy, radiusX: r, radiusY: r)
            case "ellipse":
                let cx = length("cx", width)
                let cy = length("cy", height)
                // 片方が書いていないか `auto` なら、もう片方を使う (SVG 2)。両方がそうなら 0 で描かない
                let writtenRx = optional("rx", width, allowsAuto: true)
                let writtenRy = optional("ry", height, allowsAuto: true)
                let rx = writtenRx ?? writtenRy ?? 0
                let ry = writtenRy ?? writtenRx ?? 0
                guard !unreadable, rx > 0, ry > 0 else { return nil }
                outline = .ellipse(centerX: cx, centerY: cy, radiusX: rx, radiusY: ry)
            case "line":
                let from = SIMD2(length("x1", width), length("y1", height))
                let to = SIMD2(length("x2", width), length("y2", height))
                guard !unreadable else { return nil }
                outline = .line(from: from, to: to)
            default:  // polyline / polygon
                let read = SVGFile.parsePoints(attributes["points"] ?? "")
                if !read.isComplete {
                    tally.note("<\(name) points> after \(read.points.count) points", line: line)
                }
                guard let first = read.points.first, read.points.count >= 2 else { return nil }
                outline = .path([
                    Subpath(
                        start: first, segments: read.points.dropFirst().map { .line($0) },
                        isClosed: name == "polygon")
                ])
            }
            return outline
        }

        /// 輪郭に描き方を添えて、描くものに足す。塗りも線も見えなければ足さない。
        private mutating func add(_ outline: Outline, _ context: Context, line: Int) {
            func color(_ paint: Paint, opacity: Float) -> Color? {
                let base: Color
                switch paint {
                case .none: return nil
                case .color(let read): base = read
                case .currentColor: base = context.color
                }
                var painted = base
                painted.alpha *= opacity * context.opacity
                return painted.alpha > 0 ? painted : nil
            }
            var fill: Color?
            if case .line = outline {
                fill = nil
            } else {
                fill = color(context.fill, opacity: context.fillOpacity)
                if context.fillIsReference { tally.note("fill=\"url(…)\"", line: line) }
            }
            let stroke = context.strokeWidth > 0 ? color(context.stroke, opacity: context.strokeOpacity) : nil
            if context.strokeIsReference { tally.note("stroke=\"url(…)\"", line: line) }
            if stroke != nil, context.isDashed { tally.note("stroke-dasharray", line: line) }
            if fill == nil && stroke == nil { return }
            noteOpacityApproximations(outline, context, hasFill: fill != nil, hasStroke: stroke != nil, line: line)
            items.append(
                Item(
                    outline: outline, fill: fill, fillRule: context.fillRule, stroke: stroke,
                    strokeWidth: context.strokeWidth, cap: context.cap, join: context.join,
                    transform: context.transform))
        }

    /// 描くもの 1 つについて、`opacity` を子の色ごとに掛ける近似が SVG と違う絵になるかを見て、
    /// なるなら名乗りに数える (#2884)。
    ///
    /// 違う絵になるのは 2 つの場合である。**開いている半透明の群の中で、描くものどうしの外接矩形が
    /// 重なる**とき (群ごとに 1 度だけ数える)。**塗りと線を両方持つものが、祖先まで含めて半透明**の
    /// とき (線の内側の半分が塗りに重なる)。外接矩形で見るので、実際の形は重ならないのに名乗ることが
    /// ある (名乗り過ぎる側に倒す)。
    private mutating func noteOpacityApproximations(
        _ outline: Outline, _ context: Context, hasFill: Bool, hasStroke: Bool, line: Int
    ) {
        if hasFill, hasStroke, context.opacity < 1 {
            approximations.note(SVGFile.fillAndStrokeOpacityNote, line: line)
        }
        let open = stack.compactMap(\.group)
        guard !open.isEmpty else { return }
        var box = Self.box(of: outline, context.transform)
        if hasStroke { box = box.expanded(by: context.strokeWidth / 2 * context.transform.largestScale) }
        for index in open {
            if !groups[index].named, groups[index].boxes.contains(where: { $0.overlaps(box) }) {
                groups[index].named = true
                approximations.note(SVGFile.groupOpacityNote, line: groups[index].line)
            }
            // 名乗った群は、これ以上比べない
            if !groups[index].named { groups[index].boxes.append(box) }
        }
    }

    /// 輪郭の外接矩形 (形の座標)。曲線は制御点を含めた矩形にする (曲線は制御点の外へ出ない)。
    private static func box(of outline: Outline, _ transform: Affine) -> Box {
        var points: [SIMD2<Float>] = []
        switch outline {
        case .path(let subpaths):
            for subpath in subpaths {
                points.append(subpath.start)
                for segment in subpath.segments {
                    switch segment {
                    case .line(let point): points.append(point)
                    case .cubic(let first, let second, let point): points += [first, second, point]
                    }
                }
            }
        case .rect(let x, let y, let width, let height):
            points = [SIMD2(x, y), SIMD2(x + width, y), SIMD2(x, y + height), SIMD2(x + width, y + height)]
        case .ellipse(let centerX, let centerY, let radiusX, let radiusY):
            points = [
                SIMD2(centerX - radiusX, centerY - radiusY), SIMD2(centerX + radiusX, centerY - radiusY),
                SIMD2(centerX - radiusX, centerY + radiusY), SIMD2(centerX + radiusX, centerY + radiusY),
            ]
        case .line(let from, let to):
            points = [from, to]
        }
        return Box(points: points.map(transform.apply))
    }
    }

    /// 描き方として読む属性の名前 (属性に書いても `style` に書いても同じ意味のもの)。
    private static let properties: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-opacity", "stroke-width",
        "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "opacity", "color", "visibility",
        "display", "clip-path", "mask", "filter", "marker", "marker-start", "marker-mid",
        "marker-end", "mix-blend-mode",
    ]

    /// `svg` だけが、属性にも CSS にも書ける大きさの名前 (SVG 2 では CSS の性質でもある)。
    private static let sizeProperties: Set<String> = ["width", "height"]

    /// 短縮形の `marker` が決める 3 つの性質。
    private static let markerLonghands = ["marker-start", "marker-mid", "marker-end"]

    /// 描けない効果の性質 (受け継がない)。短縮形の `marker` は含めず、3 つに分けて持つ。
    private static let effectProperties: Set<String> = [
        "clip-path", "mask", "filter", "marker-start", "marker-mid", "marker-end", "mix-blend-mode",
    ]

    // MARK: - 座標の決まり

    /// `preserveAspectRatio` の読み。
    struct AspectRatio: Sendable {
        /// 寄せる向き 1 つ (`xMin`・`xMid`・`xMax` など)。
        enum Edge: Sendable, Equatable {
            case min, mid, max
        }

        /// 縦横の倍率をそろえるときの寄せ方。`nil` は `none` (縦横を別々に伸ばして枠いっぱいに写す)。
        var align: (x: Edge, y: Edge)?
        /// 枠を覆う側の倍率にそろえるか (`slice`)。`meet` (枠に収まる側) なら偽。
        var slices: Bool

        /// 書いていないときの値 (`xMidYMid meet`)。
        static let standard = AspectRatio(align: (.mid, .mid), slices: false)
    }

    /// `preserveAspectRatio` の値を読む。文法は `[defer] <align> [meet | slice]` で、`<align>` は `none` か
    /// `x{Min,Mid,Max}Y{Min,Mid,Max}`。大文字と小文字は区別しない。**読めなければ `nil`** (未知の語・余分な語・
    /// `defer` だけ・空) — 呼ぶ側が名乗り、書いていないものとして読む (#2649)。
    static func parseAspectRatio(_ text: String) -> AspectRatio? {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "defer" { words.removeFirst() }
        guard let first = words.first, words.count <= 2 else { return nil }
        let slices: Bool
        switch words.dropFirst().first {
        case nil, "meet": slices = false
        case "slice": slices = true
        default: return nil
        }
        if first == "none" { return AspectRatio(align: nil, slices: slices) }
        func edge(_ word: Substring) -> AspectRatio.Edge? {
            switch word {
            case "min": .min
            case "mid": .mid
            case "max": .max
            default: nil
            }
        }
        // `xMidYMax` は 8 文字で、`x` + 3 文字 + `y` + 3 文字
        guard first.count == 8, first.hasPrefix("x"), first.dropFirst(4).hasPrefix("y"),
            let x = edge(first.dropFirst().prefix(3)), let y = edge(first.dropFirst(5))
        else { return nil }
        return AspectRatio(align: (x, y), slices: slices)
    }

    /// `viewBox` を、幅と高さの枠へ写す変換。`preserveAspectRatio` (既定は `xMidYMid meet`) に従う。
    static func viewBoxTransform(
        _ box: [Float], width: Float, height: Float, aspect: AspectRatio
    ) -> Affine {
        var scaleX = width / box[2]
        var scaleY = height / box[3]
        if aspect.align != nil {
            let uniform = aspect.slices ? max(scaleX, scaleY) : min(scaleX, scaleY)
            scaleX = uniform
            scaleY = uniform
        }
        var offsetX = -box[0] * scaleX
        var offsetY = -box[1] * scaleY
        let spareX = width - box[2] * scaleX
        let spareY = height - box[3] * scaleY
        func shift(_ edge: AspectRatio.Edge?, _ spare: Float) -> Float {
            switch edge {
            case .mid: spare / 2
            case .max: spare
            case .min, nil: 0
            }
        }
        offsetX += shift(aspect.align?.x, spareX)
        offsetY += shift(aspect.align?.y, spareY)
        return Affine(a: scaleX, b: 0, c: 0, d: scaleY, e: offsetX, f: offsetY)
    }

    /// 角の丸い矩形の輪郭。角は楕円の 4 分の 1 の弧。
    static func roundedRect(
        x: Float, y: Float, width: Float, height: Float, rx: Float, ry: Float
    ) -> Subpath {
        var segments: [Segment] = []
        func corner(from start: SIMD2<Float>, to end: SIMD2<Float>) {
            segments += arc(
                from: start, radiusX: rx, radiusY: ry, rotation: 0, largeArc: false, sweep: true,
                to: end)
        }
        let right = x + width
        let bottom = y + height
        segments.append(.line(SIMD2(right - rx, y)))
        corner(from: SIMD2(right - rx, y), to: SIMD2(right, y + ry))
        segments.append(.line(SIMD2(right, bottom - ry)))
        corner(from: SIMD2(right, bottom - ry), to: SIMD2(right - rx, bottom))
        segments.append(.line(SIMD2(x + rx, bottom)))
        corner(from: SIMD2(x + rx, bottom), to: SIMD2(x, bottom - ry))
        segments.append(.line(SIMD2(x, y + ry)))
        corner(from: SIMD2(x, y + ry), to: SIMD2(x + rx, y))
        // 長さ 0 の直線 (角の半径が辺の半分ちょうどのとき) は落とす
        var from = SIMD2(x + rx, y)
        var kept: [Segment] = []
        for segment in segments {
            if case .line(let point) = segment, point == from { continue }
            kept.append(segment)
            switch segment {
            case .line(let point): from = point
            case .cubic(_, _, let point): from = point
            }
        }
        return Subpath(start: SIMD2(x + rx, y), segments: kept, isClosed: true)
    }

    /// 塗りの規則 `evenodd` を、本体の塗り (回り数が 0 でない所を塗る) で再現する向きに
    /// 線をそろえ直す。
    ///
    /// **入れ子の深さが偶数の線は正の向き、奇数の線は負の向きにする。** 交わらない線どうしなら、
    /// ある点を囲む線の数が奇数のときだけ回り数が 0 でなくなる — `evenodd` と同じ塗りになる。
    /// **交わる線どうしでは再現しない** (回り数で塗った絵になる)。深さは、線の始点を囲む他の線の
    /// 数で数える。
    static func alternatingWinding(_ subpaths: [Subpath]) -> [Subpath] {
        let polygons = subpaths.map(\.roughPolygon)
        return subpaths.indices.map { index in
            var depth = 0
            for other in polygons.indices where other != index {
                if contains(polygons[other], subpaths[index].start) { depth += 1 }
            }
            let positive = signedArea(polygons[index]) >= 0
            let wantsPositive = depth % 2 == 0
            return positive == wantsPositive ? subpaths[index] : subpaths[index].reversed
        }
    }

    /// 多角形の符号つき面積 (向きを見るため)。
    private static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in polygon.indices {
            let here = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            sum += here.x * next.y - next.x * here.y
        }
        return sum / 2
    }

    /// 点が多角形の内側にあるか (偶奇の数え方)。
    private static func contains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossing = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < crossing { inside.toggle() }
            }
            previous = current
        }
        return inside
    }
}
