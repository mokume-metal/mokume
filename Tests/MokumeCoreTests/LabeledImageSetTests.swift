// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `image` の範囲を `Rect` で取る形と、`set(x:y:to:)` ([#3783])。GPU を要する。
///
/// 約束は 2 つ。**同じ値を渡すと、既定のモード (`.corner`) の位置の形と絵が 1 ビットも違わない**こと
/// と、**`Rect` を取る形は ``Canvas/imageMode(_:)`` に従わない** (`.center` の後でも値のとおり左上から
/// 置く) こと。中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。
///
/// 置く絵は画素ごとに色の違うものにして、置き先と切り出しの取り違えが絵に出るようにした。どの組も
/// 「何も描いていない絵」と違うことを先に確かめる。
///
/// [#3783]: https://github.com/mokume-metal/mokume/issues/3783
@Suite(
    "image の範囲を Rect で取る形と set(x:y:to:)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledImageSetTests {
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 1 フレームだけ描いて、面の画素をビット列で返す。
    private func picture(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> [UInt16] {
        let stage = Stage()
        stage.scene = { stage in
            stage.background(10, 12, 16)
            body(stage)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try runtime.target.readPixels().components.map(\.bitPattern)
    }

    private func differing(_ one: [UInt16], _ other: [UInt16]) -> Int {
        zip(one, other).count { $0.0 != $0.1 } + abs(one.count - other.count)
    }

    /// ラベル付きの形で描いた絵と、位置の形で描いた絵が同じで、何かを描いていること。
    private func agree(
        _ name: String,
        labeled: @escaping (Stage) -> Void,
        positional: @escaping (Stage) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        let blank = try picture(gpu) { _ in }
        let expected = try picture(gpu, positional)
        let actual = try picture(gpu, labeled)
        #expect(differing(expected, blank) > 0, "\(name): 位置の形で描いた絵が空", sourceLocation: sourceLocation)
        let count = differing(actual, expected)
        #expect(count == 0, "\(name): ラベル付きの形の絵が位置の形と \(count) 成分違う", sourceLocation: sourceLocation)
    }

    /// 画素ごとに色の違う 8x6 の絵。横へ進むと赤が、縦へ進むと緑が増える。
    private static func gradient(on canvas: Canvas) -> Image? {
        guard let image = creating({ try canvas.createImage(8, 6) }) else { return nil }
        for y in 0..<6 {
            for x in 0..<8 {
                image.set(x, y, .linear(red: Float(x) / 7, green: Float(y) / 5, blue: 0.5))
            }
        }
        return image
    }

    /// 4 つの色の違う四角を描いた 8x6 の描き場所。
    private static func quarters(on canvas: Canvas) -> Canvas? {
        guard let layer = creating({ try canvas.createGraphics(8, 6) }) else { return nil }
        layer.beginDraw()
        layer.background(.linear(red: 0.9, green: 0.2, blue: 0.1))
        layer.noStroke()
        layer.fill(.linear(red: 0.1, green: 0.8, blue: 0.3))
        layer.rect(4, 0, 4, 3)
        layer.fill(.linear(red: 0.2, green: 0.3, blue: 0.9))
        layer.rect(0, 3, 4, 3)
        layer.fill(.linear(red: 0.9, green: 0.9, blue: 0.2))
        layer.rect(4, 3, 4, 3)
        layer.endDraw()
        return layer
    }

    // 置き先と切り出しは、どの 2 つの数を入れ替えても絵が変わる値
    private let destination = Rect(left: 5, top: 7, width: 41, height: 29)
    private let source = Rect(left: 1, top: 2, width: 5, height: 3)

    // MARK: - Image を置く形

    @Test("image(_:in:) は既定のモードの image(絵, 4 つの数) と同じ絵")
    func imageInRectMatches() throws {
        let destination = destination
        try agree(
            "Sketch",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, in: destination)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, 5, 7, 41, 29)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.image(tile, in: destination)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.image(tile, 5, 7, 41, 29)
            })
    }

    @Test("image(_:in:from:) は既定のモードの image(絵, 8 つの数) と同じ絵")
    func imageInRectFromRectMatches() throws {
        let (destination, source) = (destination, source)
        try agree(
            "Sketch",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, in: destination, from: source)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, 5, 7, 41, 29, 1, 2, 5, 3)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.image(tile, in: destination, from: source)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.image(tile, 5, 7, 41, 29, 1, 2, 5, 3)
            })
    }

    @Test("Rect を取る形は imageMode に従わない: .center の後でも、.corner の位置の形と同じ絵")
    func rectFormsIgnoreImageMode() throws {
        let (destination, source) = (destination, source)
        // Issue の例の値は 64x48 の面からはみ出すので、同じ形の値で見る
        try agree(
            "Sketch の image(_:in:)",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.imageMode(.center)
                stage.image(tile, in: destination)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.imageMode(.corner)
                stage.image(tile, 5, 7, 41, 29)
            })
        try agree(
            "Canvas の image(_:in:from:)",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.imageMode(.corners)
                stage.canvas.image(tile, in: destination, from: source)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.canvas.imageMode(.corner)
                stage.canvas.image(tile, 5, 7, 41, 29, 1, 2, 5, 3)
            })
        // 位置の形は .center に従うので、同じ数でも違う絵になる (従わないことの比べ先が働いている)
        let gpu = try RenderDevice()
        let centered = try picture(gpu) { stage in
            guard let tile = Self.gradient(on: stage.canvas) else { return }
            stage.imageMode(.center)
            stage.image(tile, 5, 7, 41, 29)
        }
        let labeled = try picture(gpu) { stage in
            guard let tile = Self.gradient(on: stage.canvas) else { return }
            stage.imageMode(.center)
            stage.image(tile, in: destination)
        }
        #expect(differing(centered, labeled) > 0, ".center の位置の形と Rect の形が同じ絵 — モードが効いていない")
    }

    @Test("切り出しが絵の外へ出たときも、位置の形と同じく重なった分だけを置く")
    func sourceOutsideThePictureIsClampedAlike() throws {
        let destination = destination
        let outside = Rect(left: 4, top: -2, width: 8, height: 6)
        try agree(
            "Sketch",
            labeled: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, in: destination, from: outside)
            },
            positional: { stage in
                guard let tile = Self.gradient(on: stage.canvas) else { return }
                stage.image(tile, 5, 7, 41, 29, 4, -2, 8, 6)
            })
    }

    // MARK: - Canvas (描き場所) を置く形

    @Test("描き場所を置く image(_:in:)・image(_:in:from:) は、既定のモードの位置の形と同じ絵")
    func graphicsInRectMatches() throws {
        let (destination, source) = (destination, source)
        try agree(
            "Sketch の image(_:in:)",
            labeled: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.imageMode(.center)
                stage.image(layer, in: destination)
            },
            positional: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.image(layer, 5, 7, 41, 29)
            })
        try agree(
            "Sketch の image(_:in:from:)",
            labeled: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.image(layer, in: destination, from: source)
            },
            positional: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.image(layer, 5, 7, 41, 29, 1, 2, 5, 3)
            })
        try agree(
            "Canvas の image(_:in:)",
            labeled: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.canvas.image(layer, in: destination)
            },
            positional: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.canvas.image(layer, 5, 7, 41, 29)
            })
        try agree(
            "Canvas の image(_:in:from:)",
            labeled: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.canvas.image(layer, in: destination, from: source)
            },
            positional: { stage in
                guard let layer = Self.quarters(on: stage.canvas) else { return }
                stage.canvas.image(layer, 5, 7, 41, 29, 1, 2, 5, 3)
            })
    }

    // MARK: - set(x:y:to:)

    @Test("set(x:y:to:) は set(x, y, 色) と同じ画素を書く")
    func setMatches() throws {
        let yellow = LinearRGBA.linear(red: 0.9, green: 0.8, blue: 0.1)
        // x と y は違う値にして、取り違えが別の画素に出るようにする
        try agree(
            "Sketch",
            labeled: { stage in
                for (x, y) in [(3, 40), (50, 7), (21, 30)] { stage.set(x: x, y: y, to: yellow) }
            },
            positional: { stage in
                for (x, y) in [(3, 40), (50, 7), (21, 30)] { stage.set(x, y, yellow) }
            })
        try agree(
            "Canvas",
            labeled: { stage in
                for (x, y) in [(3, 40), (50, 7), (21, 30)] { stage.canvas.set(x: x, y: y, to: yellow) }
            },
            positional: { stage in
                for (x, y) in [(3, 40), (50, 7), (21, 30)] { stage.canvas.set(x, y, yellow) }
            })
    }

    @Test("範囲の外への set(x:y:to:) は、位置の形と同じく何もしない")
    func setOutsideDoesNothingAlike() throws {
        let yellow = LinearRGBA.linear(red: 0.9, green: 0.8, blue: 0.1)
        // 範囲の外の 2 画素と、比べ先が空にならないための内側の 1 画素
        try agree(
            "Sketch",
            labeled: { stage in
                stage.set(x: -1, y: 5, to: yellow)
                stage.set(x: 70, y: 50, to: yellow)
                stage.set(x: 4, y: 9, to: yellow)
            },
            positional: { stage in
                stage.set(-1, 5, yellow)
                stage.set(70, 50, yellow)
                stage.set(4, 9, yellow)
            })
    }
}
