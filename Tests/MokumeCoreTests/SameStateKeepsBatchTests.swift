// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 同じ状態を設定し直しても列を閉じないことの検査 (#2789)。GPU を要する。
///
/// 閉じるのは、列が持つ設定が**ビット列まで**変わるときだけ。同じ値の設定し直しで閉じると、
/// 絵は同じまま 1 列にできる仕事が、呼び出しごとの列に分かれる。数でしか見えない
/// (絵は変わらない) ので、列の数 (`Canvas.batches`) と、設定し直しを省いた絵との画素の
/// bit 一致の両方で見る。
@Suite(
    "同じ状態の設定し直しでは列を閉じない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SameStateKeepsBatchTests {
    private let black = Color.linear(red: 0, green: 0, blue: 0)
    private let white = Color.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private static let level = """
        float4 paint(Fragment in, Values values) { return float4(values.level, 0.3, 0.2, 1); }
        """

    /// 列を 1 本開いておき、`change` を呼んだときに増えた列の数を返す。
    @MainActor
    private func batchesClosed(
        by change: (Canvas) -> Void, prepare: (Canvas) -> Void = { _ in }, on canvas: Canvas
    ) throws -> Int {
        var closed = -1
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.fill(white)
            prepare(canvas)
            canvas.rect(0, 0, 8, 8)  // 開いた列を 1 本持つ
            let before = canvas.batches.count
            change(canvas)
            closed = canvas.batches.count - before
        }
        return closed
    }

    // MARK: - シェーダの値

    @Test("同じ値を設定し直しても列を閉じない。値が変わるときは閉じる")
    func shaderValueClosesOnlyWhenItChanges() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.level, values: ["level": 0.7])
        func closed(_ value: ShaderValue) throws -> Int {
            try batchesClosed(by: { _ in shader.set("level", value) }, prepare: { $0.shader(shader) }, on: canvas)
        }
        #expect(try closed(0.7) == 0, "同じ値で列を閉じた")
        #expect(try closed(0.7) == 0)
        #expect(try closed(0.2) == 1, "値が変わるのに列を閉じていない")
        #expect(try closed(0.2) == 0)
    }

    @Test("+0 と -0、NaN の違いは別の値として扱い、同じ NaN は同じ値として扱う")
    func shaderValueComparesBits() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.level, values: ["level": 0])
        let nan = Float(bitPattern: 0x7fc0_0000)
        let otherNaN = Float(bitPattern: 0x7fc0_0001)
        func closed(_ value: ShaderValue) throws -> Int {
            try batchesClosed(by: { _ in shader.set("level", value) }, prepare: { $0.shader(shader) }, on: canvas)
        }
        #expect(try closed(.number(-0.0)) == 1, "+0 を -0 に変えるのに閉じていない")
        #expect(try closed(.number(-0.0)) == 0)
        #expect(try closed(.number(0.0)) == 1, "-0 を +0 に変えるのに閉じていない")
        #expect(try closed(.number(nan)) == 1)
        #expect(try closed(.number(nan)) == 0, "同じ NaN の設定し直しで閉じた")
        #expect(try closed(.number(otherNaN)) == 1, "payload の違う NaN を同じとみなした")
    }

    @Test("組の値と色の値も、成分のビット列まで同じなら閉じない")
    func shaderPairAndColorValues() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return values.tint * float4(values.at.x, values.at.y, 1, 1); }",
            values: ["at": .pair(0.5, 0.25), "tint": .color(.linear(red: 1, green: 0.5, blue: 0.25))])
        func closed(_ name: String, _ value: ShaderValue) throws -> Int {
            try batchesClosed(by: { _ in shader.set(name, value) }, prepare: { $0.shader(shader) }, on: canvas)
        }
        #expect(try closed("at", .pair(0.5, 0.25)) == 0)
        #expect(try closed("at", .pair(0.5, 0.5)) == 1)
        #expect(try closed("tint", .color(.linear(red: 1, green: 0.5, blue: 0.25))) == 0)
        #expect(try closed("tint", .color(.linear(red: 1, green: 0.5, blue: 0.5))) == 1)
    }

    @Test("宣言していない名前と型の違う値は断り、列も閉じない")
    func rejectedValuesDoNotCloseTheBatch() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.level, values: ["level": 0.7])
        func closed(_ name: String, _ value: ShaderValue) throws -> Int {
            try batchesClosed(by: { _ in shader.set(name, value) }, prepare: { $0.shader(shader) }, on: canvas)
        }
        #expect(try closed("nothing", 1) == 0)
        #expect(try closed("level", .pair(1, 2)) == 0)
        // 断った値は入っていない — 同じ値の設定し直しは、元の値と比べて閉じない
        #expect(try closed("level", 0.7) == 0)
        #expect(try closed("level", 0.1) == 1)
    }

    @Test("同じシェーダを使う別の面の列も、同じ値なら閉じず、変わるときは閉じる")
    func sharedShaderClosesEveryUserOnlyOnChange() throws {
        let gpu = try RenderDevice()
        let first = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let second = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let shader = try first.makeShader(Self.level, values: ["level": 0.7])
        var firstClosed = -1
        var secondClosed = -1
        try first.draw {
            first.shader(shader)
            first.rect(0, 0, 8, 8)
            try? second.draw {
                second.shader(shader)
                second.rect(0, 0, 8, 8)
                let (a, b) = (first.batches.count, second.batches.count)
                shader.set("level", 0.7)
                #expect(first.batches.count == a && second.batches.count == b, "同じ値で閉じた")
                shader.set("level", 0.1)
                firstClosed = first.batches.count - a
                secondClosed = second.batches.count - b
            }
        }
        #expect(firstClosed == 1 && secondClosed == 1, "値が変わるのに旧値の列を閉じていない")
    }

    // MARK: - 切り抜き

    @Test("同じ切り抜きでは閉じず、変わるときは閉じる")
    func clipClosesOnlyWhenItChanges() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.clip(4, 4, 20, 20) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.clip(4, 4, 20, 20) }, prepare: { $0.clip(4, 4, 20, 20) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.clip(4, 4, 21, 20) }, prepare: { $0.clip(4, 4, 20, 20) }, on: canvas) == 1)
        // 面の外へ出る指定は面の内へ収めてから比べる — 収めた先が同じなら同じ切り抜き
        #expect(
            try batchesClosed(by: { $0.clip(-5, -5, 500, 500) }, prepare: { $0.clip(0, 0, 64, 64) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.noClip() }, prepare: { $0.clip(0, 0, 64, 64) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.noClip() }, on: canvas) == 0)
    }

    // MARK: - 視点

    @Test("同じ視点・同じ投影では閉じず、変わるときは閉じる")
    func cameraClosesOnlyWhenItChanges() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.camera() }, on: canvas) == 0, "既定のままの camera() で閉じた")
        #expect(try batchesClosed(by: { $0.perspective() }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.ortho() }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.ortho() }, prepare: { $0.ortho() }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.camera(70, 10, 90, 32, 32, 0, 0, 1, 0) }, on: canvas) == 1)
        #expect(
            try batchesClosed(
                by: { $0.camera(70, 10, 90, 32, 32, 0, 0, 1, 0) },
                prepare: { $0.camera(70, 10, 90, 32, 32, 0, 0, 1, 0) }, on: canvas) == 0)
        let camera = Camera(
            eye: Vector3(1, 2, 90), center: Vector3(0, 0, 0), up: Vector3(0, 1, 0),
            projection: .perspective(fieldOfView: 1, aspect: 1, near: 1, far: 500))
        #expect(
            try batchesClosed(by: { $0.setCamera(camera) }, prepare: { $0.setCamera(camera) }, on: canvas) == 0)
        var moved = camera
        moved.eye.x = 2
        #expect(try batchesClosed(by: { $0.setCamera(moved) }, prepare: { $0.setCamera(camera) }, on: canvas) == 1)
    }

    @Test("視点の成分の +0 と -0 は別の視点として閉じる")
    func cameraComparesBits() throws {
        let canvas = try makeCanvas()
        var camera = Camera(
            eye: Vector3(0, 2, 90), center: Vector3(0, 0, 0), up: Vector3(0, 1, 0),
            projection: .perspective(fieldOfView: 1, aspect: 1, near: 1, far: 500))
        let positive = camera
        camera.eye.x = -0.0
        let negative = camera
        #expect(try batchesClosed(by: { $0.setCamera(negative) }, prepare: { $0.setCamera(positive) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.setCamera(negative) }, prepare: { $0.setCamera(negative) }, on: canvas) == 0)
    }

    @Test("無効な視点は断り、列も閉じない。フレームの外の視点は書かれない")
    func refusedCameraDoesNotClose() throws {
        let canvas = try makeCanvas()
        let bad = Camera(
            eye: Vector3(0, 0, 0), center: Vector3(0, 0, 0), up: Vector3(0, 1, 0),
            projection: .perspective(fieldOfView: 1, aspect: 1, near: 1, far: 500))
        #expect(try batchesClosed(by: { $0.setCamera(bad) }, on: canvas) == 0)
        canvas.camera(1, 2, 3, 0, 0, 0, 0, 1, 0)  // フレームの外 — 書かれない
        #expect(canvas.cameraStorage == nil)
    }

    // MARK: - 材質

    @Test("同じ材質では閉じず、変わるときは閉じる")
    func materialClosesOnlyWhenItChanges() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.shininess(0) }, on: canvas) == 0, "既定のままの材質で閉じた")
        #expect(try batchesClosed(by: { $0.metalness(0) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.ambient(.linear(red: 1, green: 1, blue: 1)) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.emissive(.linear(red: 0, green: 0, blue: 0)) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shininess(8) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.shininess(8) }, prepare: { $0.shininess(8) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shininess(9) }, prepare: { $0.shininess(8) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.metalness(0.5) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.emissive(.linear(red: 0.1, green: 0, blue: 0)) }, on: canvas) == 1)
    }

    @Test("材質の -0 は 0 と別の値として閉じる。範囲外の値は断り、閉じない")
    func materialComparesBitsAndRefusesBadValues() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.shininess(-0.0) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.shininess(-1) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.metalness(2) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shininess(Float.nan) }, on: canvas) == 0)
    }

    // MARK: - 周囲

    @Test("同じ周囲では閉じず、置いていないところからと変わるときは閉じる")
    func surroundingsCloseOnlyWhenTheyChange() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.surroundings(.sky) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.surroundings(.sky) }, prepare: { $0.surroundings(.sky) }, on: canvas) == 0)
        #expect(
            try batchesClosed(by: { $0.surroundings(.studio) }, prepare: { $0.surroundings(.sky) }, on: canvas) == 1)
        var negative = Surroundings.sky
        negative.top = Color(
            premultipliedRed: -1, green: negative.top.premultipliedGreen,
            blue: negative.top.premultipliedBlue, alpha: negative.top.alpha)
        #expect(try batchesClosed(by: { $0.surroundings(negative) }, on: canvas) == 0, "断った周囲で閉じた")
    }

    // MARK: - 影

    @Test("影の設定も、同じ値では閉じず、変わるときは閉じる")
    func shadowSettingsCloseOnlyWhenTheyChange() throws {
        let canvas = try makeCanvas()
        #expect(try batchesClosed(by: { $0.shadows(false) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.castShadow(true) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.receiveShadow(true) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shadowDetail(ShadowMap.defaultDetail) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shadowBias(ShadowMap.defaultBias) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shadows(true) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.castShadow(false) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.receiveShadow(false) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.shadowRange(100) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.shadowRange(100) }, prepare: { $0.shadowRange(100) }, on: canvas) == 0)
        #expect(try batchesClosed(by: { $0.shadowDetail(256) }, on: canvas) == 1)
        #expect(try batchesClosed(by: { $0.shadowBias(0.5) }, on: canvas) == 1)
    }

    // MARK: - 絵は変わらない

    /// 同じ状態の設定し直しを足した場面と、足さない場面の絵が、全 Float16 bit 一致する。
    @Test("設定し直しを省いても省かなくても、絵は全画素 bit 一致する")
    func redundantSettingsDoNotChangeThePicture() throws {
        let gpu = try RenderDevice()
        func render(redundant: Bool) throws -> [UInt16] {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
            let shader = try canvas.makeShader(Self.level, values: ["level": 0.7])
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.lights()
                canvas.surroundings(.sky)
                canvas.shininess(12)
                canvas.shader(shader)
                canvas.clip(2, 2, 60, 60)
                canvas.camera(32, 32, 120, 32, 32, 0, 0, 1, 0)
                for i in 0..<16 {
                    if redundant {
                        shader.set("level", 0.7)
                        canvas.clip(2, 2, 60, 60)
                        canvas.camera(32, 32, 120, 32, 32, 0, 0, 1, 0)
                        canvas.shininess(12)
                        canvas.surroundings(.sky)
                        canvas.shadows(false)
                    }
                    canvas.rect(Float(i % 4) * 16, Float(i / 4) * 16, 14, 14)
                    canvas.push()
                    canvas.translate(Float(i % 4) * 16 + 7, Float(i / 4) * 16 + 7, 0)
                    canvas.box(8)
                    canvas.pop()
                }
            }
            return try canvas.target.readPixels().components.map(\.bitPattern)
        }
        let plain = try render(redundant: false)
        let repeated = try render(redundant: true)
        #expect(!plain.isEmpty)
        #expect(plain == repeated, "同じ状態の設定し直しで絵が変わった")
    }

    @Test("値が交互に変わる場面でも、置いた順に値が効く")
    func alternatingValuesStillApplyInOrder() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.level, values: ["level": 0.0])
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.shader(shader)
            for i in 0..<4 {
                shader.set("level", .number(i % 2 == 0 ? 1 : 0))
                shader.set("level", .number(i % 2 == 0 ? 1 : 0))
                canvas.rect(Float(i) * 16, 0, 16, 64)
            }
        }
        #expect(canvas.get(8, 32).premultipliedRed > 0.9)
        #expect(canvas.get(24, 32).premultipliedRed < 0.1)
        #expect(canvas.get(40, 32).premultipliedRed > 0.9)
        #expect(canvas.get(56, 32).premultipliedRed < 0.1)
    }

    // MARK: - 比べる型に項目が増えたら止まる

    /// 同値判定は項目を 1 つずつ並べて比べる。項目が増えたときに比べ忘れると、変わった設定の
    /// 列を閉じずに旧値で描く。増えたら、ここが先に落ちて比べる側を直させる。
    @Test("ビット列で比べる型の項目数")
    func comparedTypesHaveTheFieldsTheComparisonKnows() {
        #expect(Mirror(reflecting: Material()).children.count == 5)
        #expect(Mirror(reflecting: Canvas.ClipRect(left: 0, top: 0, right: 0, bottom: 0)).children.count == 4)
        #expect(Mirror(reflecting: Surroundings.sky).children.count == 3)
        #expect(
            Mirror(
                reflecting: Camera(
                    eye: Vector3(0, 0, 0), center: Vector3(0, 0, 0), up: Vector3(0, 0, 0),
                    projection: .perspective(fieldOfView: 1, aspect: 1, near: 1, far: 2))
            ).children.count == 4)
        #expect(Mirror(reflecting: Color.linear(red: 0, green: 0, blue: 0)).children.count == 4)
    }
}
