// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// SVG に書いた勾配 (`<linearGradient>`・`<radialGradient>`) を読む (#3031)。
//
// **読む範囲**: `stop` (`offset`・`stop-color`・`stop-opacity`)・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform`・
// `gradientUnits` (既定は `objectBoundingBox`)・`href` (`xlink:href` を含む) による区切りの継承。
// **読まずに名乗るもの**: `spreadMethod` (`reflect`・`repeat`)・放射の焦点 (`fx`・`fy` が中心と違う・`fr` が 0 でない)・
// `href` で指した勾配の属性 (区切りだけを引き継ぐ)・11 個目からの区切り (``GradientShader/stopCapacity``)。
// 勾配は `pad` と中心の焦点として描く。
//
// 塗るのは本体の勾配 (``Gradient``) で、置く側 (``Canvas``) が `fill(_: Gradient)` を呼ぶ。線 (`stroke`) の勾配は
// 本体に無いので、`stroke="url(#…)"` はこれまでどおり読まずに名乗る。
extension SVGFile {
    /// 要素 1 つを塗る、解いた勾配。
    nonisolated struct GradientFill: Sendable, Equatable {
        /// 勾配の形 (勾配の座標)。
        nonisolated enum Geometry: Sendable, Equatable {
            /// 位置 0 が `from`、1 が `to`。
            case linear(from: SIMD2<Float>, to: SIMD2<Float>)
            /// 位置 0 が `center`、1 が `center` から `radius` 離れた円周。
            case radial(center: SIMD2<Float>, radius: Float)
        }

        /// 区切り 1 つ。
        nonisolated struct Stop: Sendable, Equatable {
            /// 色 (sRGB の成分・乗算前)。不透明度には `stop-opacity` を掛けてある。
            var color: Color
            /// 位置 (0…1)。前の区切りの位置より小さくない (SVG の約束で寄せてある)。
            var offset: Float
        }

        var geometry: Geometry
        /// 区切り。2 個以上 ``GradientShader/stopCapacity`` 個まで。
        var stops: [Stop]
        /// 勾配の座標から、塗る要素の座標への変換 (`objectBoundingBox` の外接矩形の写しと `gradientTransform` を
        /// 畳んだもの)。逆に戻せる。
        var space: Affine
    }

    /// ファイルに書かれた勾配 1 つ (読み解く前)。
    nonisolated struct GradientDefinition: Sendable {
        var isRadial: Bool
        var attributes: [String: String]
        var stops: [GradientFill.Stop]
        /// 区切りを読むときに名乗るもの (読めない `offset`・`stop-color` など)。勾配を使ったときに名乗る。
        var notes: [(what: String, line: Int)]
        var line: Int

        var element: String { isRadial ? "radialGradient" : "linearGradient" }

        /// `href` (`xlink:href` など、前置きの付いた `href` も) の値。
        var href: String? {
            attributes["href"] ?? attributes.first { $0.key.hasSuffix(":href") }?.value
        }
    }

    /// 塗りの参照 (`url(#…)`) を解いた結果。
    nonisolated enum GradientPaint: Sendable, Equatable {
        /// 指す先が無い・勾配でない (パターンなど)・ほかのファイル。代わりの色で塗り、`fill="url(…)"` を名乗る。
        case unresolved
        /// 塗らない — 区切りが 1 つも無い・`objectBoundingBox` で外接矩形の幅か高さが 0 (SVG の約束)、`href` の
        /// 指す先が無いか循環する・半径が負・`gradientTransform` がつぶれている (名乗る)。
        case nothing
        /// 1 色で塗る — 区切りが 1 つ・線形の 2 点が同じ・放射の半径が 0 (SVG の約束。後のふたつは最後の区切りの色)。
        case color(Color)
        case gradient(GradientFill)
    }

    /// 要素の名前のうち SVG の名前空間のものなら、前置きを外した名前。他の名前空間の要素なら `nil`。
    nonisolated static func localName(_ raw: String, prefix: String) -> String? {
        if !prefix.isEmpty, raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        return raw.contains(":") ? nil : raw
    }

    // MARK: - 集める

    /// ファイルの中の勾配を、書かれた場所 (`defs` の中でも外でも・後ろに書かれていても) によらず `id` ごとに集める。
    /// 同じ `id` が 2 つあれば先のもの。区切りは勾配の直下の `stop` だけを、書いた順に読む。
    nonisolated static func collectGradients(
        _ events: [Event], prefix: String, rules: [StyleRule]
    ) -> [String: GradientDefinition] {
        var found: [String: GradientDefinition] = [:]
        // 開いている要素ごとに、受け入れた勾配ならその `id`
        var open: [String?] = []
        for event in events {
            switch event {
            case .end:
                _ = open.popLast()
            case .start(let raw, let attributes, let line):
                let name = localName(raw, prefix: prefix)
                if name == "stop", let parent = open.last, let id = parent {
                    found[id]?.add(stop: attributes, line: line, rules: rules)
                    open.append(nil)
                    continue
                }
                guard name == "linearGradient" || name == "radialGradient", let id = attributes["id"],
                    found[id] == nil
                else {
                    open.append(nil)
                    continue
                }
                found[id] = GradientDefinition(
                    isRadial: name == "radialGradient", attributes: attributes, stops: [], notes: [], line: line)
                open.append(id)
            }
        }
        return found
    }

    // MARK: - 解く

    /// 塗りの参照を、要素 1 つについて解く。`notes` は名乗るもの (勾配ごとに 1 度だけ名乗るのは呼ぶ側)。
    ///
    /// - Parameters:
    ///   - outline: 塗る要素の輪郭 (`objectBoundingBox` の外接矩形を取る)。
    ///   - viewport: 割合 (`%`) の基準 (`userSpaceOnUse` の座標)。
    nonisolated static func resolveGradient(
        _ id: String?, in definitions: [String: GradientDefinition], outline: Outline, viewport: SIMD2<Float>
    ) -> (paint: GradientPaint, notes: [(what: String, line: Int)]) {
        guard let id, let definition = definitions[id] else { return (.unresolved, []) }
        var notes: [(what: String, line: Int)] = []
        let element = definition.element
        func note(_ key: String, _ text: String, line: Int = definition.line) {
            notes.append((attributeNote(of: element, key, text), line))
        }

        // 区切りは `href` を辿って引き継ぐ。属性は引き継がず、引き継がなかったものを名乗る
        var stopsOwner = definition
        var chain: [GradientDefinition] = []
        var visited: Set<String> = [id]
        var current = definition
        while let href = current.href {
            guard let target = referencedID(Substring(href)), !visited.contains(target),
                let next = definitions[target]
            else {
                notes.append((attributeNote(of: current.element, "href", href), current.line))
                break
            }
            visited.insert(target)
            chain.append(next)
            current = next
        }
        if definition.stops.isEmpty {
            guard let owner = chain.first(where: { !$0.stops.isEmpty }) else {
                // 引き継ぐ先が無いまま切れた・循環した: 塗らない (名乗り済み)。切れずに区切りが無いだけなら SVG の約束どおり
                return (.nothing, notes)
            }
            stopsOwner = owner
        }
        var inherited: Set<String> = []
        for ancestor in chain {
            let keys = ["gradientUnits", "gradientTransform", "spreadMethod"]
                + (ancestor.isRadial == definition.isRadial
                    ? (definition.isRadial ? ["cx", "cy", "r", "fx", "fy", "fr"] : ["x1", "y1", "x2", "y2"]) : [])
            for key in keys where definition.attributes[key] == nil && ancestor.attributes[key] != nil {
                if inherited.insert(key).inserted {
                    notes.append(("<\(element) \(key)> inherited through href", definition.line))
                }
            }
        }
        notes += stopsOwner.notes

        var stops = stopsOwner.stops
        guard let last = stops.last else { return (.nothing, notes) }
        if stops.count > GradientShader.stopCapacity {
            notes.append(("<\(stopsOwner.element)> stops after the first \(GradientShader.stopCapacity)", stopsOwner.line))
            stops = Array(stops.prefix(GradientShader.stopCapacity))
        }

        let attributes = definition.attributes
        var boundingBox = true
        if let text = attributes["gradientUnits"] {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "objectBoundingBox": break
            case "userSpaceOnUse": boundingBox = false
            default: note("gradientUnits", text)
            }
        }
        var transform = Affine.identity
        if let text = attributes["gradientTransform"] {
            if let read = parseTransform(text) { transform = read } else { note("gradientTransform", text) }
        }
        if let text = attributes["spreadMethod"], text.trimmingCharacters(in: .whitespacesAndNewlines) != "pad" {
            note("spreadMethod", text)
        }

        // 座標 1 つ。`objectBoundingBox` では数も百分率も外接矩形の割合、`userSpaceOnUse` では長さ (百分率は表示枠の割合)
        let diagonal = ((viewport.x * viewport.x + viewport.y * viewport.y) / 2).squareRoot()
        func coordinate(_ key: String, _ fraction: Float, _ reference: Float) -> Float {
            let base = boundingBox ? 1 : reference
            guard let text = attributes[key] else { return fraction * base }
            guard let value = parseLength(text, reference: base) else {
                note(key, text)
                return fraction * base
            }
            return value
        }

        let geometry: GradientFill.Geometry
        if definition.isRadial {
            let center = SIMD2(coordinate("cx", 0.5, viewport.x), coordinate("cy", 0.5, viewport.y))
            let radius = coordinate("r", 0.5, diagonal)
            // 焦点は読まない。中心と違う焦点・0 でない焦点の半径だけを名乗る (Inkscape は中心と同じ `fx`・`fy` を書く)
            let focus = SIMD2(
                attributes["fx"] == nil ? center.x : coordinate("fx", 0.5, viewport.x),
                attributes["fy"] == nil ? center.y : coordinate("fy", 0.5, viewport.y))
            let slack = 1e-5 * max(abs(radius), 1)
            if abs(focus.x - center.x) > slack, let text = attributes["fx"] { note("fx", text) }
            if abs(focus.y - center.y) > slack, let text = attributes["fy"] { note("fy", text) }
            if let text = attributes["fr"], coordinate("fr", 0, diagonal) != 0 { note("fr", text) }
            if radius < 0 {
                note("r", attributes["r"] ?? "")
                return (.nothing, notes)
            }
            if radius == 0 { return (.color(last.color), notes) }
            geometry = .radial(center: center, radius: radius)
        } else {
            let from = SIMD2(coordinate("x1", 0, viewport.x), coordinate("y1", 0, viewport.y))
            let to = SIMD2(coordinate("x2", 1, viewport.x), coordinate("y2", 0, viewport.y))
            if from == to { return (.color(last.color), notes) }
            geometry = .linear(from: from, to: to)
        }

        var space = transform
        if boundingBox {
            guard let box = geometryBounds(of: outline), box.high.x > box.low.x, box.high.y > box.low.y else {
                return (.nothing, notes)
            }
            let size = box.high - box.low
            space = Affine(a: size.x, b: 0, c: 0, d: size.y, e: box.low.x, f: box.low.y) * transform
        }
        guard space.inverted != nil else {
            note("gradientTransform", attributes["gradientTransform"] ?? "")
            return (.nothing, notes)
        }
        if stops.count == 1 { return (.color(stops[0].color), notes) }
        return (.gradient(GradientFill(geometry: geometry, stops: stops, space: space)), notes)
    }

    // MARK: - 外接矩形

    /// 輪郭の形だけの外接矩形 (要素の座標・線の太さを含まない)。`objectBoundingBox` の基準。**曲線は膨らみの端まで
    /// ちょうどに取る** (制御点で取ると、勾配の端が形の外へずれる)。
    nonisolated static func geometryBounds(of outline: Outline) -> Box? {
        switch outline {
        case .rect(let x, let y, let width, let height):
            return Box(low: SIMD2(x, y), high: SIMD2(x + width, y + height))
        case .ellipse(let centerX, let centerY, let radiusX, let radiusY):
            return Box(
                low: SIMD2(centerX - radiusX, centerY - radiusY), high: SIMD2(centerX + radiusX, centerY + radiusY))
        case .line(let from, let to):
            return Box(points: [from, to])
        case .path(let subpaths):
            var points: [SIMD2<Float>] = []
            for subpath in subpaths {
                var from = subpath.start
                points.append(from)
                for segment in subpath.segments {
                    switch segment {
                    case .line(let point):
                        points.append(point)
                        from = point
                    case .cubic(let first, let second, let point):
                        points.append(point)
                        points += cubicExtrema(from, first, second, point)
                        from = point
                    }
                }
            }
            return points.isEmpty ? nil : Box(points: points)
        }
    }

    /// 3 次曲線の、端点の間で x か y が折り返す点。
    nonisolated private static func cubicExtrema(
        _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>
    ) -> [SIMD2<Float>] {
        func point(_ t: Float) -> SIMD2<Float> {
            let u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
        var found: [SIMD2<Float>] = []
        for axis in 0..<2 {
            // 微分の 3 分の 1: a·t² + b·t + c
            let a = -p0[axis] + 3 * p1[axis] - 3 * p2[axis] + p3[axis]
            let b = 2 * (p0[axis] - 2 * p1[axis] + p2[axis])
            let c = p1[axis] - p0[axis]
            var roots: [Float] = []
            if abs(a) < 1e-12 {
                if abs(b) > 1e-12 { roots.append(-c / b) }
            } else {
                let discriminant = b * b - 4 * a * c
                if discriminant >= 0 {
                    let root = discriminant.squareRoot()
                    roots += [(-b + root) / (2 * a), (-b - root) / (2 * a)]
                }
            }
            for t in roots where t > 0 && t < 1 { found.append(point(t)) }
        }
        return found
    }
}

extension SVGFile.GradientDefinition {
    /// 直下の `stop` 1 つを読んで足す。`stop-color`・`stop-opacity` は属性 < `<style>` の規則 < `style` 属性の順で
    /// 重ね (`!important` が上)、読めない値は名乗って下の宣言を残す。位置は前の区切りより小さければ寄せる (SVG の約束)。
    nonisolated fileprivate mutating func add(stop attributes: [String: String], line: Int, rules: [SVGFile.StyleRule]) {
        var offset: Float = 0
        if let text = attributes["offset"] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value =
                trimmed.hasSuffix("%")
                ? DecimalText.spelled(trimmed.dropLast()).map { $0 / 100 } : DecimalText.spelled(trimmed)
            if let value, value.isFinite {
                offset = min(max(value, 0), 1)
            } else {
                notes.append((SVGFile.attributeNote(of: "stop", "offset", text), line))
            }
        }
        offset = max(offset, stops.last?.offset ?? 0)

        var candidates: [(rank: SVGFile.Rank, declaration: SVGFile.Declaration)] = []
        func collect(_ declaration: SVGFile.Declaration, _ origin: SVGFile.Rank.Origin, specificity: Int = 0) {
            guard declaration.name == "stop-color" || declaration.name == "stop-opacity" else { return }
            candidates.append(
                (SVGFile.Rank(
                    isImportant: declaration.isImportant, origin: origin, specificity: specificity,
                    order: candidates.count), declaration))
        }
        for key in ["stop-color", "stop-opacity"] {
            if let value = attributes[key] { collect(.init(name: key, value: value, isImportant: false), .attribute) }
        }
        let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        for rule in rules where rule.selector.matches(name: "stop", classes: classes) {
            for declaration in rule.declarations { collect(declaration, .rule, specificity: rule.selector.specificity) }
        }
        if let style = attributes["style"] {
            for declaration in SVGFile.parseDeclarations(style).declarations { collect(declaration, .styleAttribute) }
        }
        var color = SVGFile.Color.black
        var opacity: Float = 1
        for (_, declaration) in candidates.sorted(by: { $0.rank < $1.rank }) {
            let value = declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
            // 全体キーワードは初めの値 (`stop-color` は黒・`stop-opacity` は 1)。どちらも受け継がない性質
            let keyword = ["inherit", "initial", "unset", "revert", "revert-layer"].contains(value.lowercased())
            if declaration.name == "stop-color" {
                if keyword {
                    color = .black
                } else if let read = SVGFile.parseColor(value) {
                    color = read
                } else {
                    notes.append((SVGFile.valueNote("stop-color", value), line))
                }
            } else {
                let amount =
                    value.hasSuffix("%")
                    ? DecimalText.spelled(value.dropLast()).map { $0 / 100 } : DecimalText.spelled(value)
                if keyword {
                    opacity = 1
                } else if let amount, amount.isFinite {
                    opacity = min(max(amount, 0), 1)
                } else {
                    notes.append((SVGFile.valueNote("stop-opacity", value), line))
                }
            }
        }
        color.alpha *= opacity
        stops.append(SVGFile.GradientFill.Stop(color: color, offset: offset))
    }
}
