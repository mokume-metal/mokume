// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 描画の受け口が数をどう受け取るかを固定する検査 (#1018)。
///
/// ADR-0035 決定 7 は「6-b (整数リテラルだけの式が `Int` へ倒れる) を承知したうえで、
/// 受け口は戻さない」と決めた。**承知していることは、承知した中身を書き留めて初めて
/// 承知になる** — 受け口を将来 `Float` へ戻せば、ここが赤くなる。
///
/// 測る口は ``Transform/apply(x:y:)`` にした。`some ScalarConvertible` を受けて
/// 受け取った値をそのまま返す (単位変換の無い) 経路で、GPU を要さない。
@Suite("数の受け取り方")
struct ScalarConvertibleTests {
    private let identity = Transform.identity

    /// 整数リテラルだけで書いた式は `Int` のまま計算され、小数部が落ちる。
    ///
    /// **これは通ってしまう。** #1017 (`.pi` が解決しない) は赤くなるが、こちらは
    /// 絵だけが変わる — works の `additivewave-1.png` が 1 階調ぶん動いた経路である。
    @Test("整数リテラルだけの割り算は、整数除算になる")
    func integerLiteralsDivideAsIntegers() {
        #expect(identity.apply(x: 1 / 2, y: 0).x == 0)
        #expect(identity.apply(x: 255 * 50 / 100, y: 0).x == 127)
        #expect(identity.apply(x: 640 * 2 / 3, y: 0).x == 426)
    }

    /// **トップレベルの色と数の口も同じ受け方をする** ([#2255])。`Float` 固定だった頃は、引数の型
    /// から逆算して `1 / 2` を `Float` の 0.5 にしていた。総称の受け口では `Int` の 0 になる
    /// (ADR-0035 決定 6-b)。
    ///
    /// [#2255]: https://github.com/mokume-metal/mokume/issues/2255
    @Test("トップレベルの数の口でも、整数リテラルだけの割り算は整数除算になる")
    func integerLiteralsDivideAsIntegersAtTheTopLevel() {
        let half: Float = lerp(0, 10, 1 / 2)
        #expect(half == 0)
        let fraction: Float = lerp(0, 10, 1 / 2.0)
        #expect(fraction == 5)
        let gray: LinearRGBA = color(255 / 2)
        #expect(gray == color(Float(127)))
    }

    /// 片方に小数点を付ければ、面の案内どおり小数のまま渡る。
    @Test("片方を小数で書けば、小数のまま渡る")
    func oneFloatingLiteralKeepsThePrecision() {
        #expect(identity.apply(x: 1 / 2.0, y: 0).x == 0.5)
        #expect(identity.apply(x: 255 * 50 / 100.0, y: 0).x == 127.5)
        #expect(identity.apply(x: 640 * 2 / 3.0, y: 0).x == 640 * 2 / Float(3))
    }

    /// 面が返した数が式に入っていれば、全体が `Float` として計算される。
    @Test("面が返した数が混ざれば、整数除算にならない")
    func aFloatInTheExpressionDecidesTheType() {
        let width: Float = 1
        #expect(identity.apply(x: width * 1 / 2, y: 0).x == 0.5)
    }

    /// 決定 1 が生きていること。`Int` と `Double` の変数はそのまま渡せる。
    ///
    /// `.pi` が渡せないこと (#1017) はコンパイルエラーなので、ここでは書けない。
    /// 綴り方は ``ScalarConvertible`` の説明文と作者の読む面が持つ。
    @Test("Float・Double・Int の変数は、どれもそのまま渡せる")
    func everyStoredWidthPasses() {
        let asFloat: Float = 3.5
        let asDouble: Double = 3.5
        let asInt: Int = 3
        #expect(identity.apply(x: asFloat, y: 0).x == 3.5)
        #expect(identity.apply(x: asDouble, y: 0).x == 3.5)
        #expect(identity.apply(x: asInt, y: 0).x == 3)
    }

    /// **`Transform` のメソッドも、変数をそのまま受ける** ([#2525])。`apply` だけが総称で、積む口 (`translate`・
    /// `rotate(by:)` など) が `Float` 固定だった割れを閉じた。`let d = 2.0` を `translate(x: d, y: d)` へ
    /// 渡せ、`Float` で渡したときと同じ行列になる。
    ///
    /// 総称の口に値を渡すので、受け口を `Float` に戻すと、ここがコンパイルできず赤くなる
    /// (`some ScalarConvertible` を `Float` の引数へは渡せない)。
    ///
    /// [#2525]: https://github.com/mokume-metal/mokume/issues/2525
    private func stacked<Value: ScalarConvertible>(_ value: Value) -> Transform {
        var t = Transform.identity
        t.translate(x: value, y: value)
        t.translate(x: value, y: value, z: value)
        t.rotate(by: value)
        t.rotateX(by: value)
        t.rotateY(by: value)
        t.rotateZ(by: value)
        t.scale(x: value, y: value)
        t.scale(x: value, y: value, z: value)
        t.shearX(by: value)
        t.shearY(by: value)
        return t
    }

    @Test("Transform のメソッドは、Float・Double・Int の変数を受けて同じ行列を組む")
    func transformMethodsTakeEveryStoredWidth() {
        let asFloat: Float = 0.5
        let asDouble: Double = 0.5
        let reference = stacked(asFloat)
        // 積んでいなければ、同じになっても何も見ていない
        #expect(reference != Transform.identity)
        #expect(stacked(asDouble) == reference)
        // `Int` は小数を持てないので、`Float` の同じ値と比べる
        let asInt: Int = 2
        #expect(stacked(asInt) == stacked(Float(2)))
        #expect(stacked(asInt) != reference)
    }

    @Test("Double の変数で組んだ Transform が、Float で組んだときと同じ点を移す")
    func doubleVariablesBuildTheSameTransformAsFloat() {
        let d = 2.0
        var t = Transform.identity
        t.translate(x: d, y: d)
        t.rotate(by: d)
        var reference = Transform.identity
        reference.translate(x: Float(2), y: Float(2))
        reference.rotate(by: Float(2))
        #expect(t == reference)
        #expect(t.apply(x: 1, y: 0) == reference.apply(x: 1, y: 0))
        // 動いていなければ、同じになっても何も見ていない
        #expect(t.apply(x: 1, y: 0) != Transform.identity.apply(x: 1, y: 0))
    }

    /// 境界: `Float` で表せない端数を持つ `Double` は、受け口で `Float` へ丸まる。**`Float(0.1)` で渡したのと
    /// 同じ行列**で、`Double` のまま持ち越して別の値になることはない (ADR-0035 決定 1: 中は `Float`)。
    @Test("Float で表せない端数の Double は、Float へ丸めて渡したときと同じ行列になる")
    func doubleFractionRoundsLikeFloat() {
        let fine: Double = 0.1
        // 丸めていなければ、同じになっても何も見ていない
        #expect(Double(Float(fine)) != fine)
        var fromDouble = Transform.identity
        fromDouble.translate(x: fine, y: fine)
        fromDouble.rotate(by: fine)
        var fromFloat = Transform.identity
        fromFloat.translate(x: Float(0.1), y: Float(0.1))
        fromFloat.rotate(by: Float(0.1))
        #expect(fromDouble == fromFloat)
    }

    /// **トップレベルの色と数の口も、変数をそのまま受ける** ([#2255])。Sketch の口と同じく
    /// `Float`・`Double`・`Int` のどれで持っていても通り、`Float` で渡したときと同じ値を返す
    /// (返り値は `Float` のまま — ADR-0035 決定 3)。
    ///
    /// 式は 1 つずつ型を書いた `let` に受けてから比べる。総称の口を `#expect` の中で
    /// 連ねると、型検査が重くなる。
    ///
    /// [#2255]: https://github.com/mokume-metal/mokume/issues/2255
    @Test("トップレベルの色と数の口も、Float・Double・Int の変数をそのまま受ける")
    func topLevelColourAndNumberPortsTakeEveryStoredWidth() {
        let i: Int = 3
        let d: Double = 0.5
        let f: Float = 3

        // 数の口。`Float` で渡したときと同じ値であることと、その値そのものを見る
        let mapped: Float = map(i, 0, 10, 0, 1)
        #expect(mapped == 0.3)
        #expect(mapped == map(f, Float(0), Float(10), Float(0), Float(1)))
        let mixed: Float = lerp(0, i, d)
        #expect(mixed == 1.5)
        let held: Float = constrain(i, 0, 2)
        #expect(held == 2)
        let ratio: Float = norm(i, 0, 10)
        #expect(ratio == 0.3)
        let eased: Float = smoothstep(0, 10, i)
        let t: Float = 0.3
        #expect(eased == t * t * (3 - 2 * t))
        #expect(eased == smoothstep(Float(0), Float(10), f))
        let turned: Float = radians(i)
        #expect(turned == f * Float.pi / 180)
        let read: Float = degrees(d)
        #expect(read == Float(0.5) * 180 / Float.pi)

        // 色の口。値そのものは、別の口 (4 つの数の口・成分を読む口・間を取る計算) と突き合わせる
        let red: LinearRGBA = color(i, 0, 0)
        #expect(red == color(f, Float(0), Float(0)))
        #expect(abs(MokumeCore.red(red) - 3) < 1e-3)
        let veil: LinearRGBA = color(i, d)
        #expect(veil == color(f, f, f, Float(0.5)))
        let gray: LinearRGBA = color(i)
        #expect(gray == color(f, f, f))
        let tinted: LinearRGBA = color(hue: i, saturation: 80, brightness: 90)
        #expect(tinted == color(hue: f, saturation: Float(80), brightness: Float(90)))
        #expect(abs(hue(tinted) - 3) < 1e-2)
        let a: LinearRGBA = color(255, 170, 60)
        let b: LinearRGBA = color(40, 50, 120)
        let blended: LinearRGBA = lerpColor(a, b, d)
        let halfway = LinearRGBA(
            premultipliedRed: interpolate(a.red, b.red, 0.5),
            green: interpolate(a.green, b.green, 0.5),
            blue: interpolate(a.blue, b.blue, 0.5),
            alpha: interpolate(a.alpha, b.alpha, 0.5))
        #expect(blended == halfway)
    }
}

/// **Sketch 層・Canvas 層の、変数を渡す口の取りこぼし** ([#2524])。GPU を要する。
///
/// `orbitControl` の感度・`emit` の `rate`・`Canvas.exposure` は `Float` 固定のまま残っていて、
/// `let n = 800; emit(dust, from: e, rate: n)` や `orbitControl(k, k, k)` (`k` が `Double`) が
/// 組み立てで赤くなった。受け口を `Float` に戻すと、ここがコンパイルできず赤くなる。
///
/// 見るのは、`Float` で渡したときと**同じ状態になること**と、その値そのもの。上の
/// ``ScalarConvertibleTests`` と別の suite にしたのは、こちらだけが GPU を要するため。
///
/// [#2524]: https://github.com/mokume-metal/mokume/issues/2524
@Suite(
    "描画の周りの口も、Float・Double・Int の変数をそのまま受ける",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ScalarConvertibleSketchPortTests {

    // MARK: - 円周率の定数

    /// **`.pi` が総称の受け口で赤くなる** ([ADR-0035] 決定 6-a) — `degrees(2 * .pi)` は
    /// `ambiguous use of 'pi'` で組めない。型の決まった定数 ([#2421]) は、この受け口へ
    /// 型を名乗らずに渡せる。コンパイルエラーは検査に書けないので、渡せることだけを見る。
    ///
    /// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
    /// [#2421]: https://github.com/mokume-metal/mokume/issues/2421
    @Test("円周率の定数は、トップレベルの総称の口へそのまま渡せる")
    func piConstantsPassThroughTheGenericPorts() {
        let turn: Float = degrees(TWO_PI)
        #expect(turn == 360)
        let half: Float = map(6, 0, 12, 0, TWO_PI)
        #expect(half == Float.pi)
        let middle: Float = lerp(0, TWO_PI, 0.5)
        #expect(middle == Float.pi)
        // 式の中でも型が決まる — `Int` のリテラルと混ぜても `Float` のまま
        let quarter: Float = lerp(0, TWO_PI, 1 / 4.0)
        #expect(quarter == HALF_PI)
        let doubled: Float = degrees(2 * PI)
        #expect(doubled == 360)
        #expect(Transform.identity.apply(x: HALF_PI, y: 0).x == Float.pi / 2)
    }

    // MARK: - jumpTime

    /// 3 枚目の `draw()` で `jump` を呼び、次の枚の `time` を控える作品。
    final class Jumps: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        var jump: ((Jumps) -> Void)?
        private(set) var times: [Float] = []
        private var drawn = 0
        func draw() {
            times.append(time)
            drawn += 1
            if drawn == 3 { jump?(self) }
            background(0)
        }
    }

    private func landed(after jump: @escaping (Jumps) -> Void) throws -> Float {
        let sketch = Jumps()
        sketch.jump = jump
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 })
        defer { runtime.closePlugins() }
        for _ in 0..<4 { try runtime.advance() }
        return try #require(sketch.times.last)
    }

    /// **`jumpTime(_:)` も、変数をそのまま受ける** ([#2525])。`let s = 1.5; jumpTime(s)` (`s` は `Double`) が
    /// 組み上がり、`Float` で渡したときと同じ秒へ飛ぶ。受け口を `Float` に戻すと、ここがコンパイルできず赤くなる。
    ///
    /// [#2525]: https://github.com/mokume-metal/mokume/issues/2525
    @Test("jumpTime は、Float・Double・Int の変数を受けて同じ秒へ飛ぶ")
    func jumpTimeTakesEveryStoredWidth() throws {
        let asFloat: Float = 1.5
        let asDouble: Double = 1.5
        let asInt: Int = 2
        let reference = try landed { $0.jumpTime(asFloat) }
        // 飛んでいなければ、同じになっても何も見ていない (飛ばないなら 4 枚目は 3 / 60 秒)
        #expect(reference == 1.5)
        #expect(try landed { $0.jumpTime(asDouble) } == reference)
        #expect(try landed { $0.jumpTime(asInt) } == 2)
    }

    /// 数でない値を断って飛ばない約束は、`Double` で渡しても変わらない。負の秒は受ける。
    @Test("Double で渡した数でない秒には飛ばず、負の秒には飛ぶ")
    func jumpTimeStillRefusesWhatItCannotTake() throws {
        let notANumber: Double = .nan
        let infinite: Double = .infinity
        let steady = Float(3.0 / 60)
        #expect(try landed { $0.jumpTime(notANumber) } == steady)
        #expect(try landed { $0.jumpTime(infinite) } == steady)
        let negative: Int = -1
        #expect(try landed { $0.jumpTime(negative) } == -1)
    }

    // MARK: - Canvas.exposure

    private func exposure(after write: (Canvas) -> Void) throws -> Float {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        write(canvas)
        return canvas.target.brightness.exposure
    }

    @Test("Canvas.exposure は、Float・Double・Int の変数を受けて同じ露出にする")
    func exposureTakesEveryStoredWidth() throws {
        let asFloat: Float = 1.5
        let asDouble: Double = 1.5
        let asInt: Int = 2
        #expect(try exposure { $0.exposure(asFloat) } == 1.5)
        #expect(try exposure { $0.exposure(asDouble) } == 1.5)
        #expect(try exposure { $0.exposure(asInt) } == 2)
        // 受け口で `Float` へ丸めるので、`Double` の 1.15 は `Float` の 1.15 と同じ露出になる
        let fine: Double = 1.15
        #expect(try exposure { $0.exposure(fine) } == Float(1.15))
    }

    /// 数でない値・負の値・無限を断って露出を変えない約束 (`warnBadExposure()`) は、受け口が広がっても
    /// 変わらない。`Double` の NaN・`Int` の負の数でも同じ。
    @Test("Double・Int で渡した数でない値・負の値・無限は、露出を変えない")
    func exposureStillRefusesWhatItCannotTake() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        canvas.exposure(2)
        let notANumber: Double = .nan
        let unbounded: Double = .infinity
        let negative: Int = -1
        canvas.exposure(notANumber)
        canvas.exposure(unbounded)
        canvas.exposure(negative)
        #expect(canvas.target.brightness.exposure == 2)
        #expect(canvas.warnings.hasWarned(.badExposure))
    }

    // MARK: - orbitControl

    /// 感度を決めて `orbitControl` を呼び、効いていた視点を控えるスケッチ。呼び方 (渡す型) は
    /// 呼ぶ側が決める。
    final class Turning: Sketch {
        var control: (Turning) -> Void = { $0.orbitControl() }
        var seen: Orbit?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            control(self)
            seen = orbit
        }
    }

    /// 押して、斜めへ引きずりスクロールしたあとの視点。3 つの感度のすべてが効く入力。
    private func orbit(_ control: @escaping (Turning) -> Void) throws -> Orbit {
        let sketch = Turning()
        sketch.control = control
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 })
        let events: [InputEvent] = [
            .mouseDown(x: 10, y: 14, button: .left), .mouseMoved(x: 40, y: 24),
            .scrolled(dx: 0, dy: 2),
        ]
        for event in events {
            runtime.input.enqueue(event)
            try runtime.advance()
        }
        return try #require(sketch.seen)
    }

    @Test("orbitControl の 3 つの感度は、Float・Double・Int の変数を受けて同じ回り方をする")
    func orbitControlTakesEveryStoredWidth() throws {
        let sx: Float = 2
        let sy: Float = 3
        let sz: Float = 4
        let reference = try orbit { $0.orbitControl(sx, sy, sz) }
        // 感度が効いていなければ、同じになっても何も見ていない
        let plain = try orbit { $0.orbitControl(1, 1, 1) }
        #expect(reference.yaw != plain.yaw && reference.pitch != plain.pitch)
        #expect(reference.distance != plain.distance)

        let dx: Double = 2
        let dy: Double = 3
        let dz: Double = 4
        let fromDouble = try orbit { $0.orbitControl(dx, dy, dz) }
        #expect(fromDouble.yaw == reference.yaw)
        #expect(fromDouble.pitch == reference.pitch)
        #expect(fromDouble.distance == reference.distance)

        let ix: Int = 2
        let iy: Int = 3
        let iz: Int = 4
        let fromInt = try orbit { $0.orbitControl(ix, iy, iz) }
        #expect(fromInt.yaw == reference.yaw)
        #expect(fromInt.pitch == reference.pitch)
        #expect(fromInt.distance == reference.distance)

        // 型が混ざっても通り、既定値を省いた形も今までどおり (感度 1 と同じ) になる
        let mixed = try orbit { $0.orbitControl(ix, dy, sz) }
        #expect(mixed.yaw == reference.yaw && mixed.pitch == reference.pitch)
        let defaults = try orbit { $0.orbitControl() }
        #expect(defaults.yaw == plain.yaw && defaults.distance == plain.distance)
    }

    // MARK: - emit の rate

    /// `rate` の渡し方を呼ぶ側が決めて、1 フレームだけ粒を出すスケッチ。
    final class Emitting: Sketch {
        var write: (Emitting, Particles) -> Void = { _, _ in }
        var dust: Particles?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 32) }
        func setup() {
            randomSeed(2524)
            dust = creating({ try makeParticles(count: 256) })
        }
        func draw() {
            guard let dust else { return }
            write(self, dust)
        }
    }

    /// 1 フレーム進めたあとの、出た粒の数と粒の状態。
    private func emitted(_ write: @escaping (Emitting, Particles) -> Void) throws -> (
        count: Int, state: [Float]
    ) {
        let sketch = Emitting()
        sketch.write = write
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        defer { runtime.closePlugins() }
        try runtime.advance()
        let dust = try #require(sketch.dust, "粒を作れていない")
        return (dust.cursor, runtime.canvas.read(dust.state))
    }

    @Test("emit の rate は、Float・Double・Int の変数を受けて同じ粒を出す")
    func emitRateTakesEveryStoredWidth() throws {
        let asFloat: Float = 600
        let asDouble: Double = 600
        let asInt: Int = 600
        let reference = try emitted { $0.emit($1, from: .point(16, 16), rate: asFloat) }
        // 出ていなければ、同じになっても何も見ていない。600 / 秒 を 1 フレーム (60 fps) で 10 個
        #expect(reference.count == 10)

        let fromDouble = try emitted { $0.emit($1, from: .point(16, 16), rate: asDouble) }
        #expect(fromDouble.count == reference.count)
        #expect(fromDouble.state == reference.state)

        let fromInt = try emitted { $0.emit($1, from: .point(16, 16), rate: asInt) }
        #expect(fromInt.count == reference.count)
        #expect(fromInt.state == reference.state)
    }

    /// 数でない値・無限・負を受け口で検める約束 (ADR-0020 決定 5) は、`Double` で渡しても変わらない。
    @Test("Double で渡した数でない rate は、粒を出さず、負の rate は出さない")
    func emitRateStillRefusesWhatItCannotTake() throws {
        let notANumber: Double = .nan
        let negative: Int = -5
        #expect(try emitted { $0.emit($1, from: .point(16, 16), rate: notANumber) }.count == 0)
        #expect(try emitted { $0.emit($1, from: .point(16, 16), rate: negative) }.count == 0)
    }
}
