// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 描く口の数値版が、値を作る口 ``color(_:_:_:_:)`` と同じ色を作る ([#1385] 条件 1)。
///
/// 作者が最もよく書くのは `fill(255, 204, 0)` のほうで、`color(…)` を経由しない。
/// 目盛りの変換は ``ColorSurfaceTests`` が CoreGraphics と突き合わせているので、ここで
/// 見るのは**描く口がその変換へ数をどう渡すか** — 引数の並び・灰色の広げ方・不透明度の
/// 既定値である。どれか 1 つを取り違えても型は通り、絵がそれらしく違う色になるだけで
/// 済んでしまう。
///
/// **作者の口 (``Sketch``) から呼ぶ。** 下の層 (``Canvas``) へ渡す 1 行の中継も、
/// 取り違えれば同じ形で壊れる。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite(
    "描く口の数値版の色",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct NumericColorEntryTests {
    /// 何も描かないスケッチ。`draw()` で呼ぶ口だけを差し替える。
    final class Blank: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        var paint: (Blank) -> Void = { _ in }
        init() {}
        func draw() { paint(self) }
    }

    /// 成分がどれも違う数。**同じ数どうしを入れ替えても色は変わらない**ので、
    /// 取り違えが色に出るよう 4 つとも別の値にする。
    private static let red: Float = 230
    private static let green: Float = 120
    private static let blue: Float = 40
    private static let opacity: Float = 200
    /// 灰色の 1 値版に渡す数。不透明度は上と別の値にする。
    private static let gray: Float = 90
    private static let grayOpacity: Float = 170

    /// 状態を読める 3 つの口。下地は状態を持ち越さない (フレームごとの予定) ので、
    /// 画素で見る別の検査にしてある。
    enum Entry: CaseIterable, CustomTestStringConvertible {
        case fill, stroke, tint

        var testDescription: String {
            switch self {
            case .fill: "fill"
            case .stroke: "stroke"
            case .tint: "tint"
            }
        }

        func call(_ sketch: Blank, _ values: [Float]) {
            switch (self, values.count) {
            case (.fill, 1): sketch.fill(values[0])
            case (.fill, 2): sketch.fill(values[0], values[1])
            case (.fill, 3): sketch.fill(values[0], values[1], values[2])
            case (.fill, _): sketch.fill(values[0], values[1], values[2], values[3])
            case (.stroke, 1): sketch.stroke(values[0])
            case (.stroke, 2): sketch.stroke(values[0], values[1])
            case (.stroke, 3): sketch.stroke(values[0], values[1], values[2])
            case (.stroke, _): sketch.stroke(values[0], values[1], values[2], values[3])
            case (.tint, 1): sketch.tint(values[0])
            case (.tint, 2): sketch.tint(values[0], values[1])
            case (.tint, 3): sketch.tint(values[0], values[1], values[2])
            case (.tint, _): sketch.tint(values[0], values[1], values[2], values[3])
            }
        }

        func read(_ canvas: Canvas) -> LinearRGBA {
            switch self {
            case .fill: canvas.style.fill
            case .stroke: canvas.style.stroke
            case .tint: canvas.style.tint
            }
        }
    }

    /// 渡す数と、同じ数を `color(…)` に渡した色。綴りは 4 通り (3 つ・4 つ・灰色・灰色と不透明度)。
    private static var forms: [(values: [Float], expected: LinearRGBA)] {
        [
            ([red, green, blue], color(red, green, blue)),
            ([red, green, blue, opacity], color(red, green, blue, opacity)),
            ([gray], color(gray)),
            ([gray, grayOpacity], color(gray, grayOpacity)),
        ]
    }

    /// 作者の口は走っているランタイムを通るので、検査からもそれを差してから呼ぶ。
    private func runSketch(_ runtime: SketchRuntime, _ body: () -> Void) {
        let previous = runningSketch
        runningSketch = runtime
        defer { runningSketch = previous }
        body()
    }

    @Test("数値版と灰色 1 値版は、同じ数の color(…) と同じ色になる", arguments: Entry.allCases)
    func numericFormsMatchTheColorValue(_ entry: Entry) throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runSketch(runtime) {
            for form in Self.forms {
                entry.call(sketch, form.values)
                // **等値で見る。** どちらも同じ目盛りの変換 (`DisplayScale.color`) を通るので、
                // 数の渡し方が同じなら最下位ビットまで一致する
                #expect(
                    entry.read(runtime.canvas) == form.expected,
                    "\(entry.testDescription)(\(form.values)) が color(\(form.values)) と違う色になった")
            }
        }
    }

    @Test("数値版の塗りと線は、止めていた塗りと線を戻す")
    func numericFormsTurnDrawingBackOn() throws {
        // 説明の約束「塗りを止めていたら、呼んだ時点で再び塗るようになる」
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runSketch(runtime) {
            sketch.noFill()
            sketch.fill(Self.gray)
            #expect(runtime.canvas.style.hasFill)
            sketch.noStroke()
            sketch.stroke(Self.red, Self.green, Self.blue)
            #expect(runtime.canvas.style.hasStroke)
        }
    }

    @Test("下地の数値版と灰色 1 値版は、同じ数の color(…) と同じ絵になる")
    func backgroundFormsMatchTheColorValue() throws {
        /// 下地を 1 度塗ったフレームの画素。
        func painted(_ paint: @escaping (Blank) -> Void) throws -> [UInt8] {
            let sketch = Blank()
            sketch.paint = paint
            let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
            try runtime.advance()
            return try runtime.target.encodeForDisplay().bytes
        }
        let (r, g, b, a) = (Self.red, Self.green, Self.blue, Self.opacity)
        let (gray, grayOpacity) = (Self.gray, Self.grayOpacity)
        #expect(try painted { $0.background(r, g, b) } == painted { $0.background(color(r, g, b)) })
        #expect(
            try painted { $0.background(r, g, b, a) } == painted { $0.background(color(r, g, b, a)) })
        #expect(try painted { $0.background(gray) } == painted { $0.background(color(gray)) })
        #expect(
            try painted { $0.background(gray, grayOpacity) }
                == painted { $0.background(color(gray, grayOpacity)) })
    }

    // MARK: - 不透明度の範囲の外 (#1450)

    /// 範囲の外の不透明度と、それを締めた端の値。
    private static let opacityEnds: [(outside: Float, end: Float)] = [(-100, 0), (400, 255)]

    @Test("不透明度に範囲の外を渡すと、端の値を渡したのと同じ色が置かれる", arguments: Entry.allCases)
    func opacityOutsideTheScaleMatchesTheEnd(_ entry: Entry) throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runSketch(runtime) {
            // 2 引数 (灰色と不透明度) と 4 引数の両方
            for colour in [[Self.gray], [Self.red, Self.green, Self.blue]] {
                for (outside, end) in Self.opacityEnds {
                    entry.call(sketch, colour + [outside])
                    let placed = entry.read(runtime.canvas)
                    entry.call(sketch, colour + [end])
                    #expect(
                        placed == entry.read(runtime.canvas),
                        "\(entry.testDescription)(\(colour + [outside])) が \(entry.testDescription)(\(colour + [end])) と違う色になった")
                }
            }
        }
    }

    /// 下地は合成ではなくクリア色なので、範囲の外の不透明度がそのまま画素に載る
    /// (`background(128, -100)` は赤 -0.085・不透明度 -0.39 だった)。**線形の値で見る** —
    /// 画面の値 (`encodeForDisplay`) は出口で標準レンジへ収めるので、違いが消えうる。
    @Test("下地の不透明度に範囲の外を渡すと、端の値を渡したのと同じ画素になる")
    func backgroundOpacityOutsideTheScaleMatchesTheEnd() throws {
        func painted(_ paint: @escaping (Blank) -> Void) throws -> PixelBuffer {
            let sketch = Blank()
            sketch.paint = paint
            let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
            try runtime.advance()
            return try runtime.target.readPixels()
        }
        #expect(try painted { $0.background(128, -100) } == painted { $0.background(128, 0) })
        #expect(try painted { $0.background(128, 400) } == painted { $0.background(128) })
        #expect(
            try painted { $0.background(128, 64, 0, -100) } == painted { $0.background(128, 64, 0, 0) })
        #expect(
            try painted { $0.background(128, 64, 0, 400) } == painted { $0.background(128, 64, 0) })
    }

    /// Issue の再現そのもの: `background(128)` の上に不透明度だけを変えた白い矩形を置き、
    /// 中央を `get` で読む。締めないと、-100 は下地を負の値 (赤 -0.092) へ落とし、400 は
    /// 白を越える (赤 1.445)。
    @Test("塗りの不透明度に範囲の外を渡した矩形は、端の値で塗った矩形と同じ画素になる")
    func fillOpacityOutsideTheScalePaintsLikeTheEnd() throws {
        func centre(afterFillingWith opacity: Float) throws -> LinearRGBA {
            let sketch = Blank()
            var sampled = LinearRGBA.transparent
            sketch.paint = { sketch in
                sketch.background(128)
                sketch.noStroke()
                sketch.fill(255, opacity)
                sketch.rect(0, 0, 8, 8)
                sampled = sketch.get(4, 4)
            }
            let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
            try runtime.advance()
            return sampled
        }
        let untouched = try centre(afterFillingWith: 0)
        let opaque = try centre(afterFillingWith: 255)
        // 不透明度 0 の矩形は下地を残す (赤 0.216)。ここが崩れると下の比較が意味を失う
        #expect(abs(untouched.red - TransferFunction.decode(128 / 255)) < 1e-3)
        let belowTheScale = try centre(afterFillingWith: -100)
        let aboveTheScale = try centre(afterFillingWith: 400)
        #expect(belowTheScale == untouched)
        #expect(aboveTheScale == opaque)
    }

    // MARK: - 色の値と不透明度 (#1553)

    /// 色の値と不透明度を取る 2 つの口。`tint` / `background` にはこの形を置かない ([#1553])。
    ///
    /// [#1553]: https://github.com/mokume-metal/mokume/issues/1553
    enum OpacityEntry: CaseIterable, CustomTestStringConvertible {
        case fill, stroke

        var testDescription: String {
            switch self {
            case .fill: "fill"
            case .stroke: "stroke"
            }
        }

        func call(_ sketch: Blank, _ color: LinearRGBA, _ alpha: Float) {
            switch self {
            case .fill: sketch.fill(color, alpha)
            case .stroke: sketch.stroke(color, alpha)
            }
        }

        func read(_ canvas: Canvas) -> LinearRGBA {
            switch self {
            case .fill: canvas.style.fill
            case .stroke: canvas.style.stroke
            }
        }
    }

    /// 半透明の色 (不透明度 128)。**不透明な色では掛け算と置き換えが一致する**ので、
    /// 置き換えの実装を見分けるにはこれが要る。
    private static let halfOpaque = color(230, 120, 40, 128)

    /// 手本 (Processing の `colorCalcARGB`) と、作品が手で書いた `fade` と同じく、色が元から
    /// 持つ不透明度に `alpha / 255` を**掛ける**。
    @Test("色の値と不透明度の形は、色が元から持つ不透明度に掛ける", arguments: OpacityEntry.allCases)
    func colorWithOpacityMultipliesTheOpacity(_ entry: OpacityEntry) throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let read = { entry.read(runtime.canvas) }
        runSketch(runtime) {
            // 不透明な色では、掛け算と置き換えが一致する — 4 つ目に不透明度を書いた色と同じ
            entry.call(sketch, color(230, 120, 40), 200)
            #expect(read() == color(230, 120, 40, 200))

            // 半透明の色に 255 を渡しても、不透明にはならない (置き換えならここで 255 になる)
            entry.call(sketch, Self.halfOpaque, 255)
            #expect(read() == Self.halfOpaque)

            // 128 × 128 / 255。色みは動かない
            entry.call(sketch, Self.halfOpaque, 128)
            let halved = read()
            #expect(abs(alpha(halved) - 128 * 128 / 255) < 1e-3, "\(alpha(halved))")
            // 成分の読み出しは名前が static の数と重なるので、モジュール名で呼ぶ
            #expect(abs(MokumeCore.red(halved) - 230) < 0.01, "\(MokumeCore.red(halved))")
            #expect(abs(MokumeCore.green(halved) - 120) < 0.01, "\(MokumeCore.green(halved))")
            #expect(abs(MokumeCore.blue(halved) - 40) < 0.01, "\(MokumeCore.blue(halved))")

            // 作品が手で書いていた `fade(c, 0.72)` — 乗算済みの 4 成分を同じ率で縮める式
            let ink = LinearRGBA.display(red: 0.114, green: 0.110, blue: 0.118)
            entry.call(sketch, ink, 0.72 * 255)
            let faded = read()
            #expect(abs(faded.red - ink.red * 0.72) < 1e-6, "\(faded)")
            #expect(abs(faded.green - ink.green * 0.72) < 1e-6, "\(faded)")
            #expect(abs(faded.blue - ink.blue * 0.72) < 1e-6, "\(faded)")
            #expect(abs(faded.alpha - ink.alpha * 0.72) < 1e-6, "\(faded)")
        }
    }

    /// 受け口は `some ScalarConvertible` で、色は `.display(…)` の暗黙メンバでも書ける。
    /// 型が決まらなければ、ここがコンパイルできずに落ちる。
    @Test("不透明度は Int の変数も Double の式も受け、色は暗黙メンバでも書ける")
    func colorWithOpacityAcceptsTheUsualSpellings() throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runSketch(runtime) {
            let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
            sketch.fill(red, 128)
            let expected = runtime.canvas.style.fill
            let count = 128
            sketch.fill(red, count)
            #expect(runtime.canvas.style.fill == expected)
            let half: Double = 64
            sketch.fill(red, half * 2.0)
            #expect(runtime.canvas.style.fill == expected)
            sketch.fill(.display(red: 1, green: 0, blue: 0), 128)
            #expect(runtime.canvas.style.fill == expected)
            sketch.stroke(.display(red: 1, green: 0, blue: 0), count)
            #expect(runtime.canvas.style.stroke == expected)
        }
    }

    @Test("色の値と不透明度の形も、止めていた塗りと線を戻す")
    func colorWithOpacityTurnsDrawingBackOn() throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        runSketch(runtime) {
            sketch.noFill()
            sketch.fill(Self.halfOpaque, 128)
            #expect(runtime.canvas.style.hasFill)
            sketch.noStroke()
            sketch.stroke(Self.halfOpaque, 128)
            #expect(runtime.canvas.style.hasStroke)
        }
    }

    /// 締めるのは**掛ける率**で、積ではない。積を締めると、半透明の色に 255 を越える値を
    /// 渡したとき元の色より不透明になる (`fill(color(…, 128), 400)` が約 201)。
    @Test("範囲の外の不透明度は掛ける率を締め、色の成分は締めない", arguments: OpacityEntry.allCases)
    func colorWithOpacityClampsTheOpacityOnly(_ entry: OpacityEntry) throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let read = { entry.read(runtime.canvas) }
        runSketch(runtime) {
            entry.call(sketch, Self.halfOpaque, 400)
            let above = read()
            entry.call(sketch, Self.halfOpaque, 255)
            #expect(above == read())
            #expect(above == Self.halfOpaque)

            entry.call(sketch, Self.halfOpaque, -100)
            #expect(read() == .transparent)

            // 255 を越える成分は、白を越える明るさのまま残る
            entry.call(sketch, color(510, 0, 0), 128)
            #expect(abs(MokumeCore.red(read()) - 510) < 0.01, "\(MokumeCore.red(read()))")
        }
    }
}

/// 色相・彩度・明度の 6 つの区画 ([#1385] 条件 2)。GPU は要らない。
///
/// ``HueSaturationBrightnessTests`` は原色 3 つ (区画の境) と 200 度の往復だけを見ている。
/// 区画ごとに成分の並びを切り替える式 (``HueSaturationBrightness/components(hue:saturation:brightness:)``
/// の `switch`) は、境では 2 つの区画の式が同じ値を出すので、並びを取り違えても境の検査は
/// 緑のままになる。**区画の中ほど** (30 度刻みの奇数倍) を見る。
///
/// 期待値は教科書の HSV → RGB の式から手で出したもの。明度 V・彩度 S・色相 H について
/// C = V·S、X = C·(1 − |(H/60) mod 2 − 1|)、m = V − C で、区画ごとに (C, X, 0) の並びを
/// 入れ替えて m を足す。30 度刻みの奇数倍では X = C/2 になる。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite("色相の 6 つの区画")
struct HueSectorTests {
    private func isSame(_ one: LinearRGBA, _ other: LinearRGBA, within tolerance: Float = 1e-5)
        -> Bool
    {
        abs(one.red - other.red) < tolerance && abs(one.green - other.green) < tolerance
            && abs(one.blue - other.blue) < tolerance && abs(one.alpha - other.alpha) < tolerance
    }

    /// 彩度 100・明度 100 では m = 0・C = 255・X = 127.5。
    nonisolated static var fullColors: [(hue: Float, rgb: SIMD3<Float>)] {
        [
            (30, SIMD3(255, 127.5, 0)),
            (90, SIMD3(127.5, 255, 0)),
            (180, SIMD3(0, 255, 255)),
            (270, SIMD3(127.5, 0, 255)),
            (330, SIMD3(255, 0, 127.5)),
        ]
    }

    /// 彩度 50・明度 80 では m = 0.4・C = 0.4・X = 0.2 (180 度だけは区画の境なので X = C)。
    /// **m が 0 でない**ので、底上げの足し忘れもここで見える。
    nonisolated static var mutedColors: [(hue: Float, rgb: SIMD3<Float>)] {
        [
            (30, SIMD3(204, 153, 102)),
            (90, SIMD3(153, 204, 102)),
            (180, SIMD3(102, 204, 204)),
            (270, SIMD3(153, 102, 204)),
            (330, SIMD3(204, 102, 153)),
        ]
    }

    @Test("彩度 100・明度 100 の中間の角度が、式から出した RGB と一致する", arguments: fullColors)
    func fullColorsMatchTheFormula(_ sample: (hue: Float, rgb: SIMD3<Float>)) {
        let rgb = sample.rgb
        #expect(
            isSame(
                color(hue: sample.hue, saturation: 100, brightness: 100),
                color(rgb.x, rgb.y, rgb.z)),
            "色相 \(sample.hue) 度が \(rgb) にならない")
    }

    @Test("彩度 50・明度 80 の中間の角度が、式から出した RGB と一致する", arguments: mutedColors)
    func mutedColorsMatchTheFormula(_ sample: (hue: Float, rgb: SIMD3<Float>)) {
        let rgb = sample.rgb
        #expect(
            isSame(
                color(hue: sample.hue, saturation: 50, brightness: 80),
                color(rgb.x, rgb.y, rgb.z)),
            "色相 \(sample.hue) 度が \(rgb) にならない")
    }

    /// 6 つの区画それぞれの中ほど。読み出しの側 (``hue(_:)``) も、最大の成分が
    /// 赤・緑・青のどれかで式を 3 通りに分けるので、区画を全部通すと 3 通りとも通る。
    @Test("6 つの区画すべてで、書いた色相・彩度・明度が読み出せる", arguments: [20, 80, 140, 200, 260, 320] as [Float])
    func everySectorRoundTrips(_ written: Float) {
        let made = color(hue: written, saturation: 70, brightness: 85)
        #expect(abs(hue(made) - written) < 0.01, "色相 \(written) 度が \(hue(made)) 度で戻った")
        #expect(abs(saturation(made) - 70) < 0.01)
        #expect(abs(brightness(made) - 85) < 0.01)
    }
}
