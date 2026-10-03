// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `background()` の口は、どれも**同じ規則で面を置き換える** ([#1685])。違うのは置く中身 (1 色か、
/// 視点から見た周囲か) だけである。
///
/// 規則は 4 つで、口の並び (``Mouth``) と組にして同じ形で回す。**口を足したら並びに足すだけ**で、
/// 同じ性質が回る。
///
/// 1. 呼んだ時点の混ぜ方を見ない ([#1658])
/// 2. 同じフレームの途中の描き切り (`loadPixels()` / `get()`) に左右されない ([#1657])
/// 3. 切り抜きの中だけを置き換える。外に先に置いたものは残り、中は色も奥行きも置き換わる ([#1648])
/// 4. 呼んだ時点の図形のスタイル (断片・影を落とすか) を拾わない
/// 5. 視点 (投影の手前と奥) に左右されない。塗り直しの道と置き換える列の道が同じ絵になる
/// 6. 後の置き換えは、前に予定した塗り直しを打ち消す
///
/// 比べる幅は成分の差 1/255 (表示の 1 段)。
///
/// [#1648]: https://github.com/mokume-metal/mokume/issues/1648
/// [#1657]: https://github.com/mokume-metal/mokume/issues/1657
/// [#1658]: https://github.com/mokume-metal/mokume/issues/1658
/// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
@Suite(
    "background() の口は、どれも同じ規則で面を置き換える",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct BackgroundReplacementTests {
    /// 面の一辺。
    static let size = 64

    /// `background()` の口。
    enum Mouth: CaseIterable, CustomTestStringConvertible {
        /// 不透明な 1 色。
        case colour
        /// 半透明の 1 色。置き換えるので、面が半透明になる。
        case translucentColour
        /// 周囲 (視点から見た空)。
        case surroundings

        var testDescription: String {
            switch self {
            case .colour: "background(色)"
            case .translucentColour: "background(半透明の色)"
            case .surroundings: "background(.sky)"
            }
        }

        /// 面を置き換える。
        func replace(on canvas: Canvas) {
            switch self {
            case .colour: canvas.background(LinearRGBA.linear(red: 0.8, green: 0.1, blue: 0.05))
            case .translucentColour:
                canvas.background(LinearRGBA(straightRed: 0.2, green: 0.6, blue: 0.3, alpha: 0.5))
            case .surroundings: canvas.background(Surroundings.sky)
            }
        }
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    /// 1 枚ずつ描いて、各フレームの後の絵を返す。
    private func frames(_ count: Int, _ body: (Canvas) throws -> Void) throws -> [PixelBuffer] {
        let canvas = try makeCanvas()
        var pictures: [PixelBuffer] = []
        for _ in 0..<count {
            var failure: (any Error)?
            try canvas.draw {
                do { try body(canvas) } catch { failure = error }
            }
            if let failure { throw failure }
            pictures.append(try canvas.target.readPixels())
        }
        return pictures
    }

    /// 1 枚だけ描いた絵。
    private func picture(_ body: (Canvas) throws -> Void) throws -> PixelBuffer {
        try frames(1, body)[0]
    }

    /// 2 枚の絵で、`columns` の範囲の列のうち成分の差が 1/255 を越える画素の数。
    private func differing(
        _ a: PixelBuffer, _ b: PixelBuffer, columns: Range<Int> = 0..<BackgroundReplacementTests.size
    ) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in columns {
                let (p, q) = (a[x, y], b[x, y])
                let gap = max(
                    abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue),
                    abs(p.alpha - q.alpha))
                if gap > 1.0 / 255 { count += 1 }
            }
        }
        return count
    }

    /// 光を受ける立体を 1 つ、面の中央より左寄りに置く。`z` が大きいほど手前。
    private static func box(_ canvas: Canvas, x: Float = 24, z: Float, size: Float = 20, fill: LinearRGBA) {
        canvas.noStroke()
        canvas.fill(fill)
        canvas.push()
        canvas.translate(x, 32, z)
        canvas.box(size)
        canvas.pop()
    }

    // MARK: - 1. 混ぜ方を見ない

    @Test(
        "どの混ぜ方のままで呼んでも、.blend のまま呼んだ絵と一致する (2 枚目も)",
        arguments: Mouth.allCases, BlendMode.allCases)
    func ignoresTheBlendMode(_ mouth: Mouth, _ mode: BlendMode) throws {
        func scene(_ mode: BlendMode) -> (Canvas) -> Void {
            { canvas in
                canvas.blendMode(mode)
                mouth.replace(on: canvas)
                canvas.blendMode(.blend)
                // 置き換えた後に描くものは、いつもどおり重なる
                canvas.noStroke()
                canvas.fill(LinearRGBA.linear(red: 0.1, green: 0.3, blue: 0.9))
                canvas.rect(40, 8, 16, 16)
            }
        }
        let subject = try frames(2, scene(mode))
        let reference = try frames(2, scene(.blend))
        for frame in 0..<2 {
            #expect(
                differing(subject[frame], reference[frame]) == 0,
                "\(frame + 1) 枚目: \(mode) のまま呼んだ絵が、.blend のまま呼んだ絵と違う")
        }
    }

    // MARK: - 2. 途中の描き切りに左右されない

    /// 置き換える前に挟む描き切り。
    enum Cut: CaseIterable, CustomTestStringConvertible {
        case loadPixels
        case get

        var testDescription: String {
            switch self {
            case .loadPixels: "loadPixels()"
            case .get: "get()"
            }
        }

        func perform(on canvas: Canvas) {
            switch self {
            case .loadPixels: canvas.loadPixels()
            case .get: _ = canvas.get(0, 0)
            }
        }
    }

    @Test(
        "立体を置いて描き切らせてから呼んでも、描き切らせない絵と一致する",
        arguments: Mouth.allCases, Cut.allCases)
    func ignoresAnEarlierCut(_ mouth: Mouth, _ cut: Cut) throws {
        func scene(cutting: Bool) -> (Canvas) -> Void {
            { canvas in
                canvas.lights()
                Self.box(canvas, x: 32, z: 0, size: 30, fill: .linear(red: 1, green: 1, blue: 1))
                if cutting { cut.perform(on: canvas) }
                mouth.replace(on: canvas)
                // 置き換えた後に置く立体は、いつもどおり手前に出る
                Self.box(canvas, x: 48, z: -10, size: 12, fill: .linear(red: 0.9, green: 0.7, blue: 0.1))
            }
        }
        let subject = try picture(scene(cutting: true))
        let reference = try picture(scene(cutting: false))
        #expect(
            differing(subject, reference) == 0,
            "\(cut) を挟むと、挟まない絵と \(differing(subject, reference)) 画素違う")
    }

    // MARK: - 3. 切り抜きの中だけを置き換える

    @Test("切り抜きの中で呼ぶと、中だけが置き換わり、外に先に置いたものは残る", arguments: Mouth.allCases)
    func replacesOnlyInsideTheClip(_ mouth: Mouth) throws {
        /// 切り抜きは左半分 (x < 32)。
        let inside = 0..<(Self.size / 2)
        let outside = (Self.size / 2)..<Self.size
        let blue = LinearRGBA.linear(red: 0.05, green: 0.1, blue: 0.6)
        let green = LinearRGBA.linear(red: 0.1, green: 0.9, blue: 0.1)
        /// 呼ぶ前に置くもの。手前の赤い箱は切り抜きの縁をまたぐ。
        func before(_ canvas: Canvas) {
            canvas.background(blue)
            canvas.noStroke()
            canvas.fill(green)
            canvas.rect(44, 0, 12, Self.size)
            canvas.lights()
            Self.box(canvas, x: 32, z: 20, size: 24, fill: .linear(red: 0.9, green: 0.1, blue: 0.1))
        }
        /// 呼んだ後に置くもの。奥の白い箱は手前の赤い箱と重なる位置にあり、切り抜きの中では
        /// 奥行きも置き換わっているので見える。
        func after(_ canvas: Canvas) {
            Self.box(canvas, x: 24, z: -20, size: 16, fill: .linear(red: 1, green: 1, blue: 1))
        }

        let subject = try picture { canvas in
            before(canvas)
            canvas.clip(0, 0, Self.size / 2, Self.size)
            mouth.replace(on: canvas)
            after(canvas)
            canvas.noClip()
        }
        // 外: 呼ぶ前の絵のまま
        let untouched = try picture { before($0) }
        #expect(
            differing(subject, untouched, columns: outside) == 0,
            "切り抜きの外が、呼ぶ前の絵と \(differing(subject, untouched, columns: outside)) 画素違う")
        // 中: 切り抜き無しで呼んだ絵
        let replaced = try picture { canvas in
            before(canvas)
            mouth.replace(on: canvas)
            after(canvas)
        }
        #expect(
            differing(subject, replaced, columns: inside) == 0,
            "切り抜きの中が、切り抜き無しで呼んだ絵と \(differing(subject, replaced, columns: inside)) 画素違う")
    }

    // MARK: - 4. 図形のスタイルを拾わない

    /// 呼ぶ時点で変えておくスタイル。
    enum Style: CaseIterable, CustomTestStringConvertible {
        /// 利用者の断片 (`shader()`)。
        case shader
        /// 影を落とす (`castShadow(true)` と `shadows(true)`)。比べる相手は `castShadow(false)` で呼ぶ。
        case castsShadow

        var testDescription: String {
            switch self {
            case .shader: "shader()"
            case .castsShadow: "castShadow(true)"
            }
        }
    }

    @Test("呼んだ時点の図形のスタイルを拾わない", arguments: Mouth.allCases, Style.allCases)
    func ignoresTheShapeStyle(_ mouth: Mouth, _ style: Style) throws {
        func scene(styled: Bool) -> (Canvas) throws -> Void {
            { canvas in
                // 光は奥から斜めに差し、右寄りの箱の左の面を照らす。背景の板が影を落とす側に
                // 入ると、板が光を遮ってその面が影に入る。焼く範囲は板まで届く広さにする
                canvas.shadows(true)
                canvas.shadowRange(2000)
                canvas.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2))
                canvas.directionalLight(.linear(red: 0.8, green: 0.8, blue: 0.8), 0.5, 0, 1)
                switch style {
                case .shader:
                    if styled {
                        canvas.shader(
                            try canvas.makeShader(
                                "float4 paint(Fragment in, Values values) { return float4(1, 0, 1, 1); }"))
                    }
                    mouth.replace(on: canvas)
                    canvas.resetShader()
                case .castsShadow:
                    canvas.castShadow(styled)
                    mouth.replace(on: canvas)
                    canvas.castShadow(true)
                }
                Self.box(canvas, x: 48, z: 0, size: 20, fill: .linear(red: 0.8, green: 0.8, blue: 0.8))
            }
        }
        let subject = try picture(scene(styled: true))
        let reference = try picture(scene(styled: false))
        #expect(
            differing(subject, reference) == 0,
            "\(style) のまま呼ぶと、外して呼んだ絵と \(differing(subject, reference)) 画素違う")
    }

    // MARK: - 5. 視点に左右されない

    /// 置き換える前に当てる視点。置き換える列の板は視点の写す範囲に置くので、手前と奥の面の
    /// 取り方で切り取られうる。
    enum View: CaseIterable, CustomTestStringConvertible {
        /// 既定の視点。
        case standard
        /// 手前と奥を寄せた透視 (near 99・far 100)。
        case tightPerspective
        /// 手前も奥も負の平行 (near -200・far -100)。奥の面の 98% は範囲の外になる。
        case orthographicWithNegativeFar
        /// 手前と奥を寄せた平行 (near 99・far 100)。
        case tightOrthographic

        var testDescription: String {
            switch self {
            case .standard: "既定の視点"
            case .tightPerspective: "perspective(near 99, far 100)"
            case .orthographicWithNegativeFar: "ortho(near -200, far -100)"
            case .tightOrthographic: "ortho(near 99, far 100)"
            }
        }

        func apply(to canvas: Canvas) {
            let half = Float(BackgroundReplacementTests.size) / 2
            switch self {
            case .standard: break
            case .tightPerspective: canvas.perspective(Float.pi / 3, 1, 99, 100)
            case .orthographicWithNegativeFar: canvas.ortho(-half, half, half, -half, -200, -100)
            case .tightOrthographic: canvas.ortho(-half, half, half, -half, 99, 100)
            }
        }
    }

    @Test(
        "どの視点でも、前の絵によらず置き換わり、切り抜きで面全体を囲っても同じ絵になる",
        arguments: Mouth.allCases, View.allCases)
    func ignoresTheView(_ mouth: Mouth, _ view: View) throws {
        /// `prior` で塗った面に視点を当て、置き換える。`clipped` なら面全体を囲う切り抜きの中で
        /// 置き換える (1 色でも塗り直しの道ではなく、置き換える列の道を通る)。
        func scene(prior: LinearRGBA, clipped: Bool) -> (Canvas) -> Void {
            { canvas in
                canvas.background(prior)
                view.apply(to: canvas)
                if clipped { canvas.clip(0, 0, Self.size, Self.size) }
                mouth.replace(on: canvas)
                if clipped { canvas.noClip() }
            }
        }
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
        for clipped in [false, true] {
            let overRed = try picture(scene(prior: red, clipped: clipped))
            let overGreen = try picture(scene(prior: green, clipped: clipped))
            #expect(
                differing(overRed, overGreen) == 0,
                "切り抜き\(clipped ? "あり" : "なし"): 前の絵が \(differing(overRed, overGreen)) 画素残っている")
        }
        let cleared = try picture(scene(prior: red, clipped: false))
        let drawn = try picture(scene(prior: red, clipped: true))
        #expect(
            differing(cleared, drawn) == 0,
            "面全体を囲う切り抜きの中で呼ぶと、切り抜き無しと \(differing(cleared, drawn)) 画素違う")
    }

    // MARK: - 6. 前の予定を打ち消す

    @Test("後の置き換えは、前に予定した塗り直しを打ち消す", arguments: Mouth.allCases)
    func cancelsAnEarlierRepaint(_ mouth: Mouth) throws {
        // 溜め場の量は塗り直しの予定を 1 つと数える (``Canvas/pendingAmount``)。前の予定が残ると、
        // 次の描き切りの奥行きの引き継ぎと控えの戻しが、古い予定を基準に決まる
        func pending(after body: @escaping (Canvas) -> Void) throws -> Int {
            let canvas = try makeCanvas()
            var amount = 0
            try canvas.draw {
                body(canvas)
                amount = canvas.pendingAmount
            }
            return amount
        }
        let afterRepaint = try pending { canvas in
            canvas.background(LinearRGBA.linear(red: 1, green: 0, blue: 0))
            mouth.replace(on: canvas)
        }
        let alone = try pending { mouth.replace(on: $0) }
        #expect(afterRepaint == alone, "前の塗り直しの予定が残っている (\(afterRepaint) / \(alone))")
    }
}
