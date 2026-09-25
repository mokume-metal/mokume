// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 作者が呼ぶ中継の口で描いた絵が、`Canvas` を直に呼んだ絵と一致することの検査。GPU を要する。
///
/// 描画の正しさを判定する検査は、ほぼすべて ``Canvas`` を直に呼んでいる。作者が実際に
/// 呼ぶのは `Sketch+*.swift` の中継の口 — 引数を `asFloat` に揃えて 1 行で `canvas` へ
/// 渡すだけの口 — で、**ここで引数の順を取り違えても、`Canvas` を見る検査はどれも
/// 赤くならない** ([#1387])。取り違えは例外にならず、違う絵になるだけである。
///
/// **口は、引数の多い中継から選んだ。** 取り違えの余地は引数の組の数だけあるので、
/// 引数が 4 つ以上の中継を優先し、`Sketch+*.swift` の公開の口を引数の数で並べた上のほうから
/// 取った:
///
/// | 口 | 引数 |
/// | --- | --- |
/// | `spotLight(red, green, blue, x, y, z, directionX, directionY, directionZ, angle:)` | 10 |
/// | `image(image, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)` | 9 |
/// | `camera(eyeX, eyeY, eyeZ, centerX, centerY, centerZ, upX, upY, upZ)` | 9 |
/// | `spotLight(color, x, y, z, directionX, directionY, directionZ, angle:)` | 8 |
/// | `quad(x1, y1, x2, y2, x3, y3, x4, y4)` | 8 |
/// | `arc(a, b, c, d, start, stop)` | 6 |
/// | `bezierVertex(cx1, cy1, cx2, cy2, x, y)` | 6 |
///
/// 上のほうで外したのは 2 つ。描き場所を置く `image(graphics, …)` (9) は、絵を置く形と
/// 引数の並びも中継の書き方も同じなので絵の形で代表させた。`emit` (8) は引数を名前付きで
/// 渡すので、並びを取り違える余地が小さい。6 引数の口は他にもある (`triangle`・`ortho`・
/// 0–255 の色で置く他の光) ので、足すときは ``Relay`` に 1 つ足す。引数なしの `camera()`
/// は使わない — 突き合わせたいのは引数の順であって、既定の視点ではない。
///
/// **値は、どの 2 つを入れ替えても絵が変わるものにした。** 対称な値 (幅と高さが同じ・
/// 向きの成分が同じ・同じ数が 2 か所に出る) を選ぶと、取り違えても同じ絵になって一致の
/// 検査が通ってしまう。面を正方形にしないのも同じ理由で、x と y を取り違えた絵が面の
/// 対称で重ならないようにしている。値の選び方が効いていることは
/// ``everySwapChangesThePicture(_:)`` が確かめる。
///
/// [#1387]: https://github.com/mokume-metal/mokume/issues/1387
@Suite(
    "中継の口と、Canvas を直に呼んだ絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchRelayParityTests {
    /// 検査が差し込んだ 1 枚を描くだけのスケッチ。
    ///
    /// 2 つの絵を**同じ `SketchRuntime` の組み立て**で描くために、`Canvas` を直に呼ぶ側も
    /// このスケッチの `draw()` の中から呼ぶ。違いは「口を中継で呼ぶか、`canvas` を直に
    /// 呼ぶか」の 1 点だけになる。
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 突き合わせる中継の口。並びは引数の多い順。
    enum Relay: CaseIterable, CustomTestStringConvertible {
        case numericSpotLight, image, camera, spotLight, quad, arc, bezierVertex

        var testDescription: String {
            switch self {
            case .numericSpotLight: "spotLight (0–255 の色・10 引数)"
            case .image: "image (切り出し・9 引数)"
            case .camera: "camera (9 引数)"
            case .spotLight: "spotLight (LinearRGBA・8 引数)"
            case .quad: "quad (8 引数)"
            case .arc: "arc (6 引数)"
            case .bezierVertex: "bezierVertex (6 引数)"
            }
        }
    }

    /// 口 1 つぶんの場面。
    private struct RelayScene {
        /// 口へ渡す値と、その名前。並びは口の引数の順で、**どの 2 つを入れ替えても絵が
        /// 変わる**ように選ぶ
        let arguments: [(name: String, value: Float)]
        /// 口の前後に置くもの。`call` を呼んだところに口が 1 つ入る
        let around: (Canvas, _ call: () -> Void) -> Void
        /// Sketch の中継の口で呼ぶ。
        let throughSketch: (Stage, [Float]) -> Void
        /// `Canvas` を直に呼ぶ。
        let direct: (Canvas, [Float]) -> Void

        var values: [Float] { arguments.map(\.value) }
    }

    private func scene(for relay: Relay) -> RelayScene {
        switch relay {
        case .numericSpotLight:
            // 平らな面に落ちる光の輪で見る。輪の位置・形・色のどれかが、どの入れ替えでも動く
            return RelayScene(
                arguments: [
                    ("red", 250), ("green", 180), ("blue", 90), ("x", 20), ("y", 14), ("z", 40),
                    ("directionX", 0.3), ("directionY", 0.2), ("directionZ", -1), ("angle", 0.45),
                ],
                around: Self.litPlane,
                throughSketch: { $0.spotLight($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7], $1[8], angle: $1[9]) },
                direct: { $0.spotLight($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7], $1[8], angle: $1[9]) })
        case .image:
            // 画素ごとに色の違う絵を切り出すので、切り出す場所を取り違えると写る色が変わる
            return RelayScene(
                arguments: [
                    ("a", 4), ("b", 9), ("c", 40), ("d", 30),
                    ("sourceX", 1), ("sourceY", 2), ("sourceWidth", 5), ("sourceHeight", 3),
                ],
                around: { _, call in call() },
                throughSketch: { stage, v in
                    guard let picture = Self.gradient(on: stage.canvas) else { return }
                    stage.image(picture, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
                },
                direct: { canvas, v in
                    guard let picture = Self.gradient(on: canvas) else { return }
                    canvas.image(picture, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
                })
        case .camera:
            // 辺の長さが 3 つとも違う箱を、斜めから少し傾けて見る。上方向の成分も 3 つとも
            // 違えてあるので、上方向の中での取り違えも傾きの違いとして出る
            return RelayScene(
                arguments: [
                    ("eyeX", 52), ("eyeY", 6), ("eyeZ", 70),
                    ("centerX", 30), ("centerY", 26), ("centerZ", -8),
                    ("upX", 0.3), ("upY", 1), ("upZ", 0.15),
                ],
                around: { canvas, call in
                    call()
                    canvas.lights()
                    canvas.push()
                    canvas.translate(32, 24, 0)
                    canvas.box(26, 16, 10)
                    canvas.pop()
                },
                throughSketch: { $0.camera($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7], $1[8]) },
                direct: { $0.camera($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7], $1[8]) })
        case .spotLight:
            let color = LinearRGBA.linear(red: 2.5, green: 2, blue: 1.5)
            return RelayScene(
                arguments: [
                    ("x", 20), ("y", 14), ("z", 40),
                    ("directionX", 0.3), ("directionY", 0.2), ("directionZ", -1), ("angle", 0.45),
                ],
                around: Self.litPlane,
                throughSketch: { $0.spotLight(color, $1[0], $1[1], $1[2], $1[3], $1[4], $1[5], angle: $1[6]) },
                direct: { $0.spotLight(color, $1[0], $1[1], $1[2], $1[3], $1[4], $1[5], angle: $1[6]) })
        case .quad:
            return RelayScene(
                arguments: [
                    ("x1", 6), ("y1", 8), ("x2", 54), ("y2", 4),
                    ("x3", 60), ("y3", 40), ("x4", 10), ("y4", 44),
                ],
                around: { _, call in call() },
                throughSketch: { $0.quad($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7]) },
                direct: { $0.quad($1[0], $1[1], $1[2], $1[3], $1[4], $1[5], $1[6], $1[7]) })
        case .arc:
            // 幅と高さを違え、始まりと終わりも違える。入れ替えると終わりが始まりより小さくなり、
            // 何も描かれない絵になる
            return RelayScene(
                arguments: [("a", 30), ("b", 22), ("c", 44), ("d", 28), ("start", 0.6), ("stop", 4.1)],
                around: { _, call in call() },
                throughSketch: { $0.arc($1[0], $1[1], $1[2], $1[3], $1[4], $1[5]) },
                direct: { $0.arc($1[0], $1[1], $1[2], $1[3], $1[4], $1[5]) })
        case .bezierVertex:
            // 始点から曲線で繋いで閉じた形を塗る。制御点と終点のどれが動いても塗る範囲が変わる
            return RelayScene(
                arguments: [("cx1", 50), ("cy1", 4), ("cx2", 60), ("cy2", 38), ("x", 12), ("y", 44)],
                around: { canvas, call in
                    canvas.beginShape()
                    canvas.vertex(6, 10)
                    call()
                    canvas.endShape(.close)
                },
                throughSketch: { $0.bezierVertex($1[0], $1[1], $1[2], $1[3], $1[4], $1[5]) },
                direct: { $0.bezierVertex($1[0], $1[1], $1[2], $1[3], $1[4], $1[5]) })
        }
    }

    // MARK: - 場面の部品

    /// 描く面いっぱいの板に、置いた光だけを当てる。
    private static func litPlane(_ canvas: Canvas, _ call: () -> Void) {
        call()
        canvas.push()
        canvas.translate(32, 24, 0)
        canvas.plane(64, 48)
        canvas.pop()
    }

    /// 画素ごとに色の違う 8x6 の絵。横へ進むと赤が、縦へ進むと緑が増える。
    private static func gradient(on canvas: Canvas) -> Image? {
        guard let image = try? canvas.createImage(8, 6) else { return nil }
        for y in 0..<6 {
            for x in 0..<8 {
                image.set(x, y, .linear(red: Float(x) / 7, green: Float(y) / 5, blue: 0.5))
            }
        }
        return image
    }

    /// 1 フレームだけ描いて、面の画素をビット列で返す。
    ///
    /// 下地と塗りは口によらず同じものを先に敷く。**比べるのは作業空間の半精度の値の
    /// ビット列そのもの**である — 表示用の 8 bit へ落としてから比べると、落とす段で
    /// 潰れる差を見逃す。
    private func picture(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> [UInt16] {
        let stage = Stage()
        stage.scene = { stage in
            stage.canvas.background(.linear(red: 0.02, green: 0.03, blue: 0.05))
            stage.canvas.noStroke()
            stage.canvas.fill(.linear(red: 0.9, green: 0.5, blue: 0.25))
            body(stage)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try runtime.target.readPixels().components.map(\.bitPattern)
    }

    /// 違っている成分の数。`#expect` に絵そのものを渡すと、落ちたときに 1 万を越える
    /// 数の列が丸ごと展開されて読めなくなるので、数に畳んでから渡す。
    private func differingComponents(_ one: [UInt16], _ other: [UInt16]) -> Int {
        zip(one, other).count { $0.0 != $0.1 } + abs(one.count - other.count)
    }

    // MARK: - 中継の口と、Canvas を直に呼んだ絵

    @Test("中継の口で描いた絵が、Canvas を直に呼んだ絵とビット列で一致する", arguments: Relay.allCases)
    func relayDrawsWhatTheCanvasDraws(_ relay: Relay) throws {
        let gpu = try RenderDevice()
        let scene = scene(for: relay)
        let values = scene.values
        let relayed = try picture(gpu) { stage in
            scene.around(stage.canvas) { scene.throughSketch(stage, values) }
        }
        let direct = try picture(gpu) { stage in
            scene.around(stage.canvas) { scene.direct(stage.canvas, values) }
        }
        let differing = differingComponents(relayed, direct)
        #expect(differing == 0, "中継の口の絵が Canvas を直に呼んだ絵と \(differing) 成分違う")
    }

    // MARK: - 値の選び方

    /// 中継の口が引数を 1 組取り違えたとき、描かれるのは「その 1 組を入れ替えて `Canvas` を
    /// 直に呼んだ絵」である。だからここで**全部の組について入れ替えた絵が元の絵と違う**
    /// ことを見ておけば、``relayDrawsWhatTheCanvasDraws(_:)`` はどの 1 組の取り違えも
    /// 見逃さない。
    ///
    /// あわせて、口を呼ばない絵とも違うこと (口が実際に何かを描いていること) を見る。
    /// 何も描かれない値を選ぶと、一致の検査は下地どうしを比べて通ってしまう。
    @Test("選んだ値は、どの 2 つを入れ替えても絵が変わる", arguments: Relay.allCases)
    func everySwapChangesThePicture(_ relay: Relay) throws {
        let gpu = try RenderDevice()
        let scene = scene(for: relay)
        func drawn(_ values: [Float]) throws -> [UInt16] {
            try picture(gpu) { stage in
                scene.around(stage.canvas) { scene.direct(stage.canvas, values) }
            }
        }
        let original = try drawn(scene.values)
        // 同じ値なら同じ絵になること。描くたびに揺れるなら、下の「違う」は値の選び方の
        // 証拠にならない
        let again = try drawn(scene.values)
        #expect(differingComponents(again, original) == 0, "同じ値で 2 度描いた絵が違う")

        let untouched = try picture(gpu) { stage in scene.around(stage.canvas) {} }
        #expect(differingComponents(original, untouched) > 0, "口を呼ばない絵と同じ — 口が何も描いていない")

        var unchanged: [String] = []
        let names = scene.arguments.map(\.name)
        for first in names.indices {
            for second in names.indices where second > first {
                var swapped = scene.values
                swapped.swapAt(first, second)
                let candidate = try drawn(swapped)
                if differingComponents(candidate, original) == 0 {
                    unchanged.append("\(names[first]) と \(names[second])")
                }
            }
        }
        #expect(unchanged.isEmpty, "入れ替えても絵が変わらない組がある: \(unchanged.joined(separator: "・"))")
    }
}
