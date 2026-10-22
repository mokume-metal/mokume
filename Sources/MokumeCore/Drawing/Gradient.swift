// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 塗りに渡す勾配。``SketchPart/fill(_:)-(Gradient)`` が受ける。
///
/// 値は `linearGradient(_:from:to:)` と `radialGradient(_:center:radius:)` で作る。区切りは
/// `(色, 位置)` の並びで、位置 0 が勾配の始まり (線形は `from`・放射は中心)、位置 1 が終わり
/// (線形は `to`・放射は `radius` だけ離れた所) になる。区切りは `(色, 位置)` をそのまま並べて渡す。
/// 並びを組み立ててから渡すときは、`[(LinearRGBA, Float)]` を受ける形もある。
///
/// **勾配が受け持つのは塗りだけである。** 線 (`stroke`) の勾配・円錐の勾配は無い。値型
/// (``Circle``・``Rect``) と ``Placement`` の `fill` は色のままで、勾配を使うなら描く状態に置く。
///
/// ```swift
/// fill(.linearGradient((color(40, 30, 90), 0), (color(250, 140, 80), 1), from: [0, 0], to: [0, height]))
/// rect(0, 0, width, height)
/// ```
public nonisolated struct Gradient: Sendable, Equatable {
    /// 勾配の区切り 1 つ。
    nonisolated struct Stop: Sendable, Equatable {
        var color: LinearRGBA
        var position: Float
    }

    nonisolated enum Kind: Sendable, Equatable {
        case linear(from: SIMD2<Float>, to: SIMD2<Float>)
        case radial(center: SIMD2<Float>, radius: Float)
    }

    let kind: Kind
    let stops: [Stop]

    /// 2 点を結ぶ向きに色が変わる勾配。
    ///
    /// 区切りの位置 0 が `start`、1 が `end` にあたる。2 点を結ぶ線に垂直な向きには色が変わらない。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// noStroke()
    /// fill(.linearGradient((color(40, 30, 90), 0), (color(250, 140, 80), 1), from: [0, 0], to: [0, height]))
    /// rect(0, 0, width, height)
    /// ```
    ///
    /// **座標は `fill(_:)` を呼んだときの座標系で読む。** `translate(_:_:)` や `rotate(_:)` の後で
    /// 呼べば、その変換が勾配の座標にも掛かる。呼んだ後に変換を変えても、勾配は動かない。
    /// ``SketchPart/createShape(_:)`` の中で呼んだ勾配は形に焼き付いて、形を ``Placement`` で動かし
    /// たり回したりすると勾配も一緒に動く。
    ///
    /// **区切りの規則**
    ///
    /// - 位置の小さい順に並べ直して使う (並べ替えは安定で、同じ位置の 2 つは書いた順)
    /// - 最初の位置より手前は最初の色、最後の位置より先は最後の色のまま伸びる
    /// - 区切りは 10 個まで。それより多い分は使わず、1 度だけ知らせる
    /// - 区切りが 1 つも無い・数でない値・無限の値を含む・`start` と `end` が同じ点のときは、勾配を
    ///   受けず (塗りは前のまま)、1 度だけ知らせる
    ///
    /// **混ぜる空間は線形で、乗算済みの値で混ぜる。** ``lerpColor(_:_:_:)`` と同じ空間なので、黒と
    /// 白の真ん中は ``red(_:)`` で約 187.5 と読める。符号化した値で混ぜる Canvas 2D の勾配
    /// (p5 の `drawingContext` で使う定番) より、中間の色が明るい。
    public static func linearGradient(
        _ stops: (LinearRGBA, Float)..., from start: Vector2, to end: Vector2
    ) -> Gradient {
        linearGradient(stops, from: start, to: end)
    }

    /// 2 点を結ぶ向きに色が変わる勾配 (区切りを配列で渡す)。
    ///
    /// 区切りを組み立ててから渡すとき (ループで作った配色など) の形で、規則は区切りを並べる形と
    /// 同じ。**配列を括弧の中へ直に書く `fill(.linearGradient([(色, 0), (色, 1)], …))` は、
    /// Swift 6.3 までは「`Int` を `Float` へ変えられない」と断られる。** 書き並べるときは配列に
    /// せず、`(色, 位置)` をそのまま並べる。
    ///
    /// ```swift
    /// let sky: [(LinearRGBA, Float)] = (0..<5).map { step in
    ///     let amount = Float(step) / 4
    ///     return (lerpColor(color(40, 30, 90), color(250, 140, 80), amount), amount)
    /// }
    /// fill(.linearGradient(sky, from: [0, 0], to: [0, height]))
    /// rect(0, 0, width, height)
    /// ```
    public static func linearGradient(
        _ stops: [(LinearRGBA, Float)], from start: Vector2, to end: Vector2
    ) -> Gradient {
        Gradient(
            kind: .linear(from: start.simd, to: end.simd),
            stops: stops.map { Stop(color: $0.0, position: $0.1) })
    }

    /// 中心から外へ広がる勾配。
    ///
    /// 区切りの位置 0 が `center`、1 が `center` から `radius` だけ離れた円周にあたる。円周より外は
    /// 最後の色のまま伸びる。
    ///
    /// ```swift
    /// background(15, 18, 23)
    /// noStroke()
    /// fill(.radialGradient((color(255, 240, 200), 0), (color(255, 160, 80, 0), 1), center: [200, 150], radius: 140))
    /// circle(200, 150, 280)
    /// ```
    ///
    /// 座標・区切りの規則・混ぜる空間は `linearGradient(_:from:to:)` と同じ。`radius` が 0 以下・
    /// 数でない値・無限のときは、勾配を受けず (塗りは前のまま)、1 度だけ知らせる。
    public static func radialGradient(
        _ stops: (LinearRGBA, Float)..., center: Vector2, radius: some ScalarConvertible
    ) -> Gradient {
        radialGradient(stops, center: center, radius: radius)
    }

    /// 中心から外へ広がる勾配 (区切りを配列で渡す)。
    ///
    /// 区切りを組み立ててから渡すときの形で、規則は区切りを並べる形と同じ。配列を括弧の中へ直に
    /// 書くと Swift 6.3 までは断られる理由は、線形の勾配 (`linearGradient(_:from:to:)`) の注記を見る。
    ///
    /// ```swift
    /// let glow: [(LinearRGBA, Float)] = [(color(255, 240, 200), 0), (color(255, 160, 80, 0), 1)]
    /// fill(.radialGradient(glow, center: [200, 150], radius: 140))
    /// circle(200, 150, 280)
    /// ```
    public static func radialGradient(
        _ stops: [(LinearRGBA, Float)], center: Vector2, radius: some ScalarConvertible
    ) -> Gradient {
        Gradient(
            kind: .radial(center: center.simd, radius: radius.asFloat),
            stops: stops.map { Stop(color: $0.0, position: $0.1) })
    }

    private init(kind: Kind, stops: [Stop]) {
        self.kind = kind
        self.stops = stops
    }
}

/// 2 次元のアフィン変換。変換の行列 (``Canvas/transform``) の平面の部分。
struct Affine2: Sendable, Equatable {
    /// 列 (x の向き・y の向き)。
    var xAxis: SIMD2<Float>
    var yAxis: SIMD2<Float>
    var translation: SIMD2<Float>

    static let identity = Affine2(xAxis: SIMD2(1, 0), yAxis: SIMD2(0, 1), translation: .zero)

    init(xAxis: SIMD2<Float>, yAxis: SIMD2<Float>, translation: SIMD2<Float>) {
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.translation = translation
    }

    init(_ matrix: simd_float4x4) {
        xAxis = SIMD2(matrix.columns.0.x, matrix.columns.0.y)
        yAxis = SIMD2(matrix.columns.1.x, matrix.columns.1.y)
        translation = SIMD2(matrix.columns.3.x, matrix.columns.3.y)
    }

    func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
        xAxis * point.x + yAxis * point.y + translation
    }

    /// 逆の変換。つぶれた変換 (行列式が 0 か数でない) は `nil`。
    var inverse: Affine2? {
        let determinant = xAxis.x * yAxis.y - yAxis.x * xAxis.y
        guard determinant.isFinite, determinant != 0 else { return nil }
        let scale = 1 / determinant
        let inverseX = SIMD2(yAxis.y, -xAxis.y) * scale
        let inverseY = SIMD2(-yAxis.x, xAxis.x) * scale
        let moved = Affine2(xAxis: inverseX, yAxis: inverseY, translation: .zero)
        return Affine2(
            xAxis: inverseX, yAxis: inverseY, translation: -moved.apply(translation))
    }

    /// `self` を先に、`other` を後に掛けた変換 (`other(self(p))`)。
    func then(_ other: Affine2) -> Affine2 {
        Affine2(
            xAxis: other.xAxis * xAxis.x + other.yAxis * xAxis.y,
            yAxis: other.xAxis * yAxis.x + other.yAxis * yAxis.y,
            translation: other.apply(translation))
    }
}

/// 塗りの状態に置く、解いた勾配 (``Canvas/Style/gradient``)。
///
/// **勾配は `fill(_:)` を呼んだときの座標系で読む。** 呼んだときの変換 (``matrix``) を覚え、描く面の
/// 座標から勾配の位置を出す式 (``mapping``) を作る。形に焼き付けるとき (保持した形・
/// ``Canvas/createShape(_:)``) は、置く変換の逆を ``mapping`` へ掛け直す (``rebased(by:)``)。
///
/// **参照型にしてある** — スタイルは積み降ろしのたびに丸ごと写されるので、勾配を持たない (`nil` の)
/// ときに写す費用が増えないようにする (勾配を値で持つと、スタイルが 130 バイトほど大きくなり、
/// `pushStyle()` と `fill(_:)` を毎回呼ぶ円 4000 個が release で 29% 遅くなった)。
final class ResolvedGradient: Sendable, Equatable {
    /// 勾配の区切りの数の上限。値の区画 (``Canvas/valueSlotCapacity``) に収まる数で、
    /// ``GradientShader`` の宣言が持つ。
    static let stopCapacity = GradientShader.stopCapacity

    let source: Gradient
    /// `fill(_:)` を呼んだときの変換 (勾配の座標 → 描く面の座標)。
    let matrix: Affine2
    /// 位置の小さい順に並べた区切り (``stopCapacity`` 個まで)。
    let stops: [Gradient.Stop]
    /// 描く面の座標 `(x, y)` から勾配の位置を出す式。`t = a·x + b·y + c`。線形は `row0` だけ、放射は
    /// `row0` と `row1` が 2 つの成分で、位置は 2 つの成分の長さになる。
    let row0: SIMD3<Float>
    let row1: SIMD3<Float>
    var isRadial: Bool {
        if case .radial = source.kind { return true }
        return false
    }

    /// 勾配が受けられなかった理由。
    enum Problem: Equatable {
        case noStops
        case badStop
        case badGeometry
        case tooManyStops
    }

    /// 解く。受けられなければ理由を返す。**区切りが多すぎるだけなら受けて**、使った分を返す
    /// (`truncated` が立つ)。
    static func resolve(
        _ source: Gradient, under matrix: Affine2
    ) -> (gradient: ResolvedGradient?, problem: Problem?) {
        guard !source.stops.isEmpty else { return (nil, .noStops) }
        for stop in source.stops {
            guard stop.position.isFinite, stop.color.isFinite else { return (nil, .badStop) }
        }
        guard let inverse = matrix.inverse else { return (nil, .badGeometry) }
        let rows: (SIMD3<Float>, SIMD3<Float>)
        switch source.kind {
        case .linear(let from, let to):
            let span = to - from
            let lengthSquared = span.x * span.x + span.y * span.y
            guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite,
                lengthSquared.isFinite, lengthSquared > 0
            else { return (nil, .badGeometry) }
            // t = (span · (A·P + b − from)) / |span|²。A は逆の変換の線形の部分、b は平行移動
            let scale = 1 / lengthSquared
            let along = SIMD2(
                (span.x * inverse.xAxis.x + span.y * inverse.xAxis.y) * scale,
                (span.x * inverse.yAxis.x + span.y * inverse.yAxis.y) * scale)
            let offset =
                (span.x * (inverse.translation.x - from.x) + span.y * (inverse.translation.y - from.y))
                * scale
            rows = (SIMD3(along.x, along.y, offset), .zero)
        case .radial(let center, let radius):
            guard center.x.isFinite, center.y.isFinite, radius.isFinite, radius > 0 else {
                return (nil, .badGeometry)
            }
            // u = (A·P + b − center) / radius の 2 成分
            let scale = 1 / radius
            let row0 = SIMD3(
                inverse.xAxis.x * scale, inverse.yAxis.x * scale,
                (inverse.translation.x - center.x) * scale)
            let row1 = SIMD3(
                inverse.xAxis.y * scale, inverse.yAxis.y * scale,
                (inverse.translation.y - center.y) * scale)
            rows = (row0, row1)
        }
        guard rows.0.x.isFinite, rows.0.y.isFinite, rows.0.z.isFinite, rows.1.x.isFinite,
            rows.1.y.isFinite, rows.1.z.isFinite
        else { return (nil, .badGeometry) }
        let sorted = source.stops.enumerated().sorted {
            $0.element.position != $1.element.position
                ? $0.element.position < $1.element.position : $0.offset < $1.offset
        }.map(\.element)
        let truncated = sorted.count > stopCapacity
        let used = Array(sorted.prefix(stopCapacity))
        return (
            ResolvedGradient(source: source, matrix: matrix, stops: used, row0: rows.0, row1: rows.1),
            truncated ? .tooManyStops : nil
        )
    }

    static func == (lhs: ResolvedGradient, rhs: ResolvedGradient) -> Bool {
        lhs === rhs
            || (lhs.source == rhs.source && lhs.matrix == rhs.matrix && lhs.stops == rhs.stops
                && lhs.row0 == rhs.row0 && lhs.row1 == rhs.row1)
    }

    private init(
        source: Gradient, matrix: Affine2, stops: [Gradient.Stop], row0: SIMD3<Float>,
        row1: SIMD3<Float>
    ) {
        self.source = source
        self.matrix = matrix
        self.stops = stops
        self.row0 = row0
        self.row1 = row1
    }

    /// 呼んだときの変換を `matrix` に置き直して解く。形の組み立ての入口で、外で決めた勾配を形自身の座標で
    /// 読み直すのに使う。
    func rebased(to matrix: Affine2) -> ResolvedGradient? {
        Self.resolve(source, under: matrix).gradient
    }

    /// 描く面の座標を `placement` で動かした先で読む式へ直した値の並び。**保持した形を置くとき**に、
    /// 記録した値 (`values`) の式へ、置く変換の逆を掛ける。置いた形の頂点は `placement` で動くので、
    /// 勾配も一緒に動く。
    static func rebasing(_ values: [Float], by placement: Affine2) -> [Float]? {
        guard let inverse = placement.inverse, values.count >= GradientShader.layout.count else {
            return nil
        }
        var result = values
        let layout = GradientShader.layout
        func row(_ x: Int, _ y: Int, _ c: Int) {
            let a = values[x], b = values[y], c0 = values[c]
            // 記録した式 t = a·x' + b·y' + c0 の (x', y') を、置いた先の座標 (x, y) の逆写しにする
            result[x] = a * inverse.xAxis.x + b * inverse.xAxis.y
            result[y] = a * inverse.yAxis.x + b * inverse.yAxis.y
            result[c] = a * inverse.translation.x + b * inverse.translation.y + c0
        }
        row(layout.row0, layout.row0 + 1, layout.offset)
        row(layout.row1, layout.row1 + 1, layout.offset + 1)
        return result
    }

    /// 断片へ渡す値の並び (``GradientShader/declarations`` の宣言と同じ並び)。
    var packedValues: [Float] {
        var packed = [Float](repeating: 0, count: GradientShader.layout.count)
        let layout = GradientShader.layout
        packed[layout.row0] = row0.x
        packed[layout.row0 + 1] = row0.y
        packed[layout.row1] = row1.x
        packed[layout.row1 + 1] = row1.y
        packed[layout.offset] = row0.z
        packed[layout.offset + 1] = row1.z
        packed[layout.info] = isRadial ? 1 : 0
        packed[layout.info + 1] = Float(stops.count)
        for (index, stop) in stops.enumerated() {
            let color = layout.colors[index]
            packed[color] = stop.color.premultipliedRed
            packed[color + 1] = stop.color.premultipliedGreen
            packed[color + 2] = stop.color.premultipliedBlue
            packed[color + 3] = stop.color.alpha
            packed[layout.positions[index]] = stop.position
        }
        return packed
    }
}

/// 勾配で塗る断片。**面ごとに 1 つ、初めて勾配で塗るときに組む。**
///
/// 利用者の断片と同じ経路 (三角形の経路) で描くので、円も字も同じ口で塗れる。勾配で塗る頂点は
/// 不透明度を負にして印を付けてあり (``Canvas/gradientVertexColor``)、印の無い頂点 (輪郭・線) は
/// 組み込みの塗りと同じ式 (`texel * color`) で塗る。値は断片の宣言を通さず、列の値の並びへ直に
/// 書く (``ResolvedGradient/packedValues``)。
enum GradientShader {
    static let stopCapacity = 10

    /// 宣言した値。**名前は並びを決める材料でしかない** — 中身は列の値の並びへ直に書く。
    static var declarations: [String: ShaderValue] {
        var values: [String: ShaderValue] = [
            "row0": .pair(0, 0), "row1": .pair(0, 0), "offset": .pair(0, 0), "info": .pair(0, 0),
        ]
        for index in 0..<stopCapacity {
            values["color\(index)"] = .color(.transparent)
            values["position\(index)"] = .number(0)
        }
        return values
    }

    /// 値の並びの中での、各項目の先頭の位置 (宣言と同じ詰め方 ``ShaderSource/packedOffsets(of:)``)。
    struct Layout {
        let count: Int
        let row0: Int
        let row1: Int
        let offset: Int
        let info: Int
        let colors: [Int]
        let positions: [Int]
    }

    static let layout: Layout = {
        let declared = declarations
        let offsets = ShaderSource.packedOffsets(of: declared)
        return Layout(
            count: ShaderSource.pack(declared).count,
            row0: offsets["row0"]!, row1: offsets["row1"]!, offset: offsets["offset"]!,
            info: offsets["info"]!,
            colors: (0..<stopCapacity).map { offsets["color\($0)"]! },
            positions: (0..<stopCapacity).map { offsets["position\($0)"]! })
    }()

    /// 断片の原稿。
    static let body: String = {
        let colors = (0..<stopCapacity).map { "values.color\($0)" }.joined(separator: ", ")
        let positions = (0..<stopCapacity).map { "values.position\($0)" }.joined(separator: ", ")
        return """
            float4 paint(Fragment in, Values values) {
                // A gradient vertex has a negative alpha; the others (outlines, lines) paint like the built-in fill
                if (in.color.a >= 0.0) { return in.texel * in.color; }
                float2 p = in.position;
                float2 u = float2(
                    values.row0.x * p.x + values.row0.y * p.y + values.offset.x,
                    values.row1.x * p.x + values.row1.y * p.y + values.offset.y);
                float t = values.info.x < 0.5 ? u.x : length(u);
                float4 colors[\(stopCapacity)] = { \(colors) };
                float positions[\(stopCapacity)] = { \(positions) };
                uint count = uint(values.info.y + 0.5);
                float4 gradient = colors[0];
                if (t > positions[0]) {
                    gradient = colors[count - 1];
                    for (uint i = 1; i < count; i++) {
                        if (t <= positions[i]) {
                            float span = positions[i] - positions[i - 1];
                            float amount = span > 0.0 ? (t - positions[i - 1]) / span : 1.0;
                            gradient = mix(colors[i - 1], colors[i], amount);
                            break;
                        }
                    }
                }
                // The vertex colour is white times the placement tint with its alpha negated:
                // multiply the colour, and multiply the alpha with its sign restored
                return in.texel * gradient * float4(in.color.rgb, -in.color.a);
            }
            """
    }()
}
