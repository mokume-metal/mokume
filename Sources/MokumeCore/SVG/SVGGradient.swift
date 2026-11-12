// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// SVG に書いた勾配 (`<linearGradient>`・`<radialGradient>`) を読む (#3031)。
//
// **読む範囲**: `stop` (`offset`・`stop-color`・`stop-opacity`)・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform`・
// `gradientUnits` (既定は `objectBoundingBox`)・`href` (`xlink:href` を含む) による区切りの継承。
// **読まずに名乗るもの**: `spreadMethod` (`reflect`・`repeat`)・放射の焦点 (`fx`・`fy` が中心と違う・`fr` が 0 でない)・
// `href` で指した勾配の属性のうち既定と違う値 (区切りだけを引き継ぐ)・11 個目からの区切り
// (``GradientShader/stopCapacity``)・勾配と区切りの中のアニメーション。勾配は `pad` と中心の焦点・書いた値のまま描く。
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
    /// **同じ `id` は文書で最初の要素が勝つ** (ブラウザの参照と同じ)。最初の要素が勾配でなければ (`<pattern>` など)、
    /// その `id` の勾配は集めない。区切りは勾配の直下の `stop` だけを、書いた順に読む。勾配と `stop` の直下の
    /// アニメーションの要素は、読まずに勾配の名乗りに積む (形の中のアニメーションと同じ形で、静止した値で描く)。
    nonisolated static func collectGradients(
        _ events: [Event], prefix: String, rules: [StyleRule]
    ) -> [String: GradientDefinition] {
        var found: [String: GradientDefinition] = [:]
        /// 文書の中で出た `id` (要素の種類によらない)。
        var seen: Set<String> = []
        /// 開いている要素 1 つ: 受け入れた勾配 (か、その直下の `stop`) ならその `id`、と受け継ぐ塗りの値。
        struct Open {
            var gradient: String?
            var isStop = false
            var paint: StopPaint
        }
        var open: [Open] = []
        for event in events {
            switch event {
            case .end:
                _ = open.popLast()
            case .start(let raw, let attributes, let line):
                let name = localName(raw, prefix: prefix)
                let parent = open.last
                let parentPaint = parent?.paint ?? StopPaint()
                let isStop = name == "stop" && parent?.gradient != nil && parent?.isStop == false
                var notes: [(what: String, line: Int)] = []
                let paint = StopPaint(
                    attributes, name: name ?? raw, parent: parentPaint, rules: rules,
                    note: { notes.append(($0, line)) })
                defer { if let id = attributes["id"] { seen.insert(id) } }
                if let name, animationElements.contains(name), let id = parent?.gradient {
                    found[id]?.notes.append(("<\(name)>", line))
                    open.append(Open(paint: paint))
                    continue
                }
                if isStop, let id = parent?.gradient {
                    found[id]?.add(stop: attributes, line: line, paint: paint, notes: notes)
                    open.append(Open(gradient: id, isStop: true, paint: paint))
                    continue
                }
                guard name == "linearGradient" || name == "radialGradient", let id = attributes["id"],
                    !seen.contains(id)
                else {
                    open.append(Open(paint: paint))
                    continue
                }
                found[id] = GradientDefinition(
                    isRadial: name == "radialGradient", attributes: attributes, stops: [], notes: [], line: line)
                open.append(Open(gradient: id, paint: paint))
            }
        }
        return found
    }

    /// 区切りの色を決める値 (要素ごと)。`color` は受け継ぐ性質、`stop-color`・`stop-opacity` は受け継がない性質で、
    /// `inherit` のときだけ親の値を取る。
    nonisolated struct StopPaint {
        var color = Color.black
        var stopColor = Color.black
        var stopOpacity: Float = 1

        init() {}

        /// 要素の宣言 (属性 < `<style>` の規則 < `style` 属性。`!important` が上) を重ねて決める。性質ごとに、読める
        /// 宣言のうち順位が最も高い 1 つが勝つ。読めない `stop-color`・`stop-opacity` は `note` で名乗り、下の宣言を残す。
        /// `stop-color` の `currentColor` はこの要素の `color` で読む。
        init(
            _ attributes: [String: String], name: String, parent: StopPaint, rules: [StyleRule],
            note: (String) -> Void
        ) {
            let properties: Set<String> = ["color", "stop-color", "stop-opacity"]
            var candidates: [(rank: Rank, declaration: Declaration)] = []
            func collect(_ declaration: Declaration, _ origin: Rank.Origin, specificity: Int = 0) {
                guard properties.contains(declaration.name) else { return }
                candidates.append(
                    (Rank(
                        isImportant: declaration.isImportant, origin: origin, specificity: specificity,
                        order: candidates.count), declaration))
            }
            for key in ["color", "stop-color", "stop-opacity"] {
                if let value = attributes[key] { collect(.init(name: key, value: value, isImportant: false), .attribute) }
            }
            let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            for rule in rules where rule.selector.matches(name: name, classes: classes) {
                for declaration in rule.declarations { collect(declaration, .rule, specificity: rule.selector.specificity) }
            }
            if let style = attributes["style"] {
                for declaration in parseDeclarations(style).declarations { collect(declaration, .styleAttribute) }
            }
            let ordered = candidates.sorted { $0.rank < $1.rank }.map(\.declaration)
            func value(of declaration: Declaration) -> String {
                declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // `color` を先に決める (`stop-color: currentColor` が読む)。読めない値は、ここでは名乗らない (描く要素の
            // `color` は辿る側が名乗る)
            color = parent.color
            for declaration in ordered where declaration.name == "color" {
                let text = value(of: declaration).lowercased()
                switch text {
                case "inherit", "unset", "revert", "revert-layer", "currentcolor": color = parent.color
                case "initial": color = .black
                default: if let read = parseColor(text) { color = read }
                }
            }
            for declaration in ordered where declaration.name != "color" {
                let text = value(of: declaration)
                let keyword = text.lowercased()
                if declaration.name == "stop-color" {
                    switch keyword {
                    case "inherit": stopColor = parent.stopColor
                    case "initial", "unset", "revert", "revert-layer": stopColor = .black
                    case "currentcolor": stopColor = color
                    default:
                        if let read = parseColor(text) { stopColor = read } else { note(valueNote("stop-color", text)) }
                    }
                } else {
                    switch keyword {
                    case "inherit": stopOpacity = parent.stopOpacity
                    case "initial", "unset", "revert", "revert-layer": stopOpacity = 1
                    default:
                        let amount =
                            text.hasSuffix("%")
                            ? DecimalText.spelled(text.dropLast()).map { $0 / 100 } : DecimalText.spelled(text)
                        if let amount, amount.isFinite {
                            stopOpacity = min(max(amount, 0), 1)
                        } else {
                            note(valueNote("stop-opacity", text))
                        }
                    }
                }
            }
        }
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
        // 引き継がなかった属性のうち、絵を変えうるもの (既定と違う値) だけを名乗る。鎖の近いほうの値が SVG では効く
        var inherited: Set<String> = []
        for ancestor in chain {
            let keys = ["gradientUnits", "gradientTransform", "spreadMethod"]
                + (ancestor.isRadial == definition.isRadial
                    ? (definition.isRadial ? ["cx", "cy", "r", "fx", "fy", "fr"] : ["x1", "y1", "x2", "y2"]) : [])
            for key in keys where definition.attributes[key] == nil {
                guard let text = ancestor.attributes[key], inherited.insert(key).inserted else { continue }
                if !isDefault(key, text, of: definition) {
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

        // つぶれた変換は、要素によらず塗れない。名乗りを出し切るため、要素ごとに変わる外接矩形より先に見る —
        // 名乗りは勾配ごとに最初に使った要素で 1 度だけ出すので、外接矩形の幅か高さが 0 の要素で先に抜けると、
        // 後の要素で名乗る機会が無い
        guard transform.inverted != nil else {
            note("gradientTransform", attributes["gradientTransform"] ?? "")
            return (.nothing, notes)
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

    /// `href` で指した勾配の属性の値が、書いていないときと同じ絵になる値か。座標は外接矩形の割合 (と百分率) で比べる。
    nonisolated private static func isDefault(_ key: String, _ text: String, of definition: GradientDefinition) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "gradientUnits": return trimmed == "objectBoundingBox"
        case "spreadMethod": return trimmed == "pad"
        case "gradientTransform": return parseTransform(trimmed) == .identity
        default: break
        }
        // `userSpaceOnUse` の勾配では、数は長さで割合ではない。百分率だけを割合として比べる
        let userSpace = definition.attributes["gradientUnits"]?.trimmingCharacters(in: .whitespaces) == "userSpaceOnUse"
        guard !userSpace || trimmed.hasSuffix("%"), let value = parseLength(trimmed, reference: 1) else { return false }
        let fallback: Float
        switch key {
        case "x2": fallback = 1
        case "cx", "cy", "r": fallback = 0.5
        case "fx", "fy":
            // 焦点の既定は中心 (この勾配の `cx` / `cy`)
            let center = definition.attributes[key == "fx" ? "cx" : "cy"]
            guard let center else { return value == 0.5 }
            return parseLength(center, reference: 1) == value && (!userSpace || center.hasSuffix("%"))
        default: fallback = 0  // x1・y1・y2・fr
        }
        return value == fallback
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
    /// 直下の `stop` 1 つを足す。色は `paint` (``SVGFile/StopPaint``) が決めたもので、`notes` はそのときの名乗り。
    /// 位置は前の区切りより小さければ寄せ、0…1 の外は端へ寄せる (SVG の約束)。
    nonisolated fileprivate mutating func add(
        stop attributes: [String: String], line: Int, paint: SVGFile.StopPaint, notes stopNotes: [(what: String, line: Int)]
    ) {
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
        notes += stopNotes
        var color = paint.stopColor
        color.alpha *= paint.stopOpacity
        stops.append(SVGFile.GradientFill.Stop(color: color, offset: offset))
    }
}
