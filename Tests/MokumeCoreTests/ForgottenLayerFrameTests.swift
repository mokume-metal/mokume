// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 描き場所で `endDraw()` を閉じ忘れたまま、本体のフレームが進んだときの検査 ([#1834])。GPU を要する。
///
/// 閉じ忘れたフレームは**本体の次のフレームの頭で描かずに捨てる** (ADR-0021 決定 4 の
/// 2026-10-02 の改訂)。越えた状態そのものを作らないので、越えた後に描き場所へ触れる口は、
/// どれも今ある「フレームの外」の扱いに落ちる。
///
/// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
@Suite(
    "閉じ忘れた描き場所のフレーム",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ForgottenLayerFrameTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 本体のフレームの頭で捨てたときの注意。
    static let droppedAtMainFrameNotice =
        "endDraw() was not called for a beginDraw() on this canvas before the main frame moved "
        + "on, so that frame was dropped without being drawn"

    /// 捨てた後に遅れて呼んだ `endDraw()` の注意。
    static let lateEndDrawNotice =
        "endDraw(): the frame opened by beginDraw() was already dropped without being drawn, "
        + "because the main frame moved on before endDraw() was called. This call does nothing"

    /// 本体のフレームを越えた後、描き場所を `beginDraw()` で開き直す前に触れる口。
    ///
    /// **越えたフレームに描き切り・読み・実行を起こしうる口を、ここに並べる。口を足したら
    /// ここに 1 行足す** — 口ごとに守ると書き落としが黙る (ADR-0021 決定 4 の追補
    /// (2026-09-27))。並びは #1834 の「範囲」の探した式で見つかる口と揃えてある:
    ///
    /// - 読む口 3 つ (`get`・`pixels`・`loadPixels()`) × 画素だけ / 画素と図形
    /// - 他の面からの描き切り (置いた描き場所の描き換え・読み)
    /// - 数の並びの読み (`read(_ numbers:)`)
    /// - 遅れた `endDraw()`
    /// - `guard isDrawing` だけを見る口 (`emit`・`force`・`particles(_:)`・`compute`)
    enum Mouth: CaseIterable, CustomTestStringConvertible {
        case getAfterPixels, getAfterShape
        case pixelsAfterPixels, pixelsAfterShape
        case loadPixelsAfterPixels, loadPixelsAfterShape
        case redrawPlacedLayer, getPlacedLayer, loadPixelsOfPlacedLayer
        case readNumbers
        case lateEndDraw
        case emit, force, particles, compute

        var testDescription: String { "\(self)" }

        /// 閉じ忘れたフレームで図形も溜めるか。
        var placesShape: Bool {
            switch self {
            case .getAfterPixels, .pixelsAfterPixels, .loadPixelsAfterPixels: false
            default: true
            }
        }
    }

    /// 検査の道具。本体・閉じ忘れる描き場所・それに置く別の描き場所と、計算と粒。
    private struct Scene {
        let main: Canvas
        let layer: Canvas
        let other: Canvas
        let numbers: Numbers
        let stamp: Computation
        let dust: Particles
    }

    private func makeScene() throws -> Scene {
        let main = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let layer = try main.createGraphics(16, 16)
        return Scene(
            main: main, layer: layer, other: try main.createGraphics(16, 16),
            numbers: try main.makeNumbers(count: 1),
            stamp: try main.makeComputation(
                """
                kernel void stamp(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]])
                {
                    out[id] = 7;
                }
                """, name: "stamp"),
            dust: try main.makeParticles(count: 8))
    }

    private func emit(_ dust: Particles, on surface: Canvas) {
        var randomness = Randomness(seed: 1)
        surface.emit(
            dust, from: .point(8, 8), rate: 600, speed: 1...2, angle: 0...1, life: 1...2,
            size: 1...2, color: nil, using: &randomness)
    }

    /// 本体の (3, 3)・(9, 9)・(1, 1)。閉じ忘れたフレームで書いた画素・溜めた白い四角・置いた赤い
    /// 描き場所の位置である。
    private func probes(_ canvas: Canvas) throws -> [LinearRGBA] {
        let image = try canvas.target.readPixels()
        return [image[3, 3], image[9, 9], image[1, 1]]
    }

    @Test(
        "閉じ忘れたまま本体のフレームを越えた描き場所は、越えた後のどの口からも描かれない (#1834)",
        arguments: Mouth.allCases)
    func aLayerFrameLeftOpenIsDroppedBeforeAnyMouthTouchesIt(_ mouth: Mouth) throws {
        let s = try makeScene()
        let (main, layer, other) = (s.main, s.layer, s.other)
        // 1 枚目: 描き場所を黒、置く側の描き場所を赤で塗る
        try main.draw {
            layer.beginDraw()
            layer.background(black)
            layer.endDraw()
            other.beginDraw()
            other.background(red)
            other.endDraw()
        }
        #expect(layer.framesDrawn == 1)

        // 2 枚目: 描き場所を開き、書いて溜めて頼んで、`endDraw()` を書き忘れる
        try main.draw {
            layer.beginDraw()
            layer.set(3, 3, red)
            if mouth.placesShape {
                layer.noStroke()
                layer.fill(white)
                layer.rect(8, 8, 4, 4)
                layer.image(other, 0, 0, 3, 3)
                layer.compute(s.stamp, over: 1, writes: [s.numbers])
            }
        }

        // 3 枚目: 描き場所を開き直す前に、口に触れる
        var droppedAtHead = false
        var framesAtHead = 0
        var seen: [LinearRGBA] = []
        var read: [Float] = []
        let cursor = s.dust.cursor
        let forces = s.dust.pendingForceCount
        try main.draw {
            droppedAtHead = layer.warnings.hasWarned(.unfinishedFrameDropped)
            framesAtHead = layer.framesDrawn
            switch mouth {
            case .getAfterPixels, .getAfterShape:
                seen = [layer.get(3, 3), layer.get(9, 9), layer.get(1, 1)]
            case .pixelsAfterPixels, .pixelsAfterShape:
                let window = layer.pixels
                seen = [window[3, 3], window[9, 9], window[1, 1]]
            case .loadPixelsAfterPixels, .loadPixelsAfterShape:
                layer.loadPixels()
                seen = [layer.get(3, 3), layer.get(9, 9), layer.get(1, 1)]
            case .redrawPlacedLayer:
                other.beginDraw()
                other.background(green)
                other.endDraw()
            case .getPlacedLayer:
                _ = other.get(0, 0)
            case .loadPixelsOfPlacedLayer:
                other.loadPixels()
            case .readNumbers:
                read = layer.read(s.numbers)
            case .lateEndDraw:
                layer.endDraw()
                main.background(black)
                main.image(layer, 0, 0)
            case .emit:
                emit(s.dust, on: layer)
            case .force:
                layer.force(s.dust, [.gravity(0, 1)])
            case .particles:
                layer.particles(s.dust)
            case .compute:
                layer.compute(s.stamp, over: 1, writes: [s.numbers])
            }
        }
        #expect(droppedAtHead, "\(mouth): 本体の頭で捨てていない")
        #expect(framesAtHead == 2, "\(mouth): 捨てたフレームが 1 枚に数えられていない")
        #expect(layer.warnings.message(for: .unfinishedFrameDropped) == Self.droppedAtMainFrameNotice)
        if !seen.isEmpty {
            #expect(seen == [black, black, black], "\(mouth): 捨てるはずの中身を読めた")
        }
        switch mouth {
        case .readNumbers:
            #expect(read == [0], "閉じ忘れたフレームで頼んだ計算が走った")
        case .lateEndDraw:
            #expect(try probes(main) == [black, black, black], "遅れた endDraw() が閉じ忘れたフレームを描いた")
            #expect(layer.warnings.message(for: .endDrawAfterFrameDropped) == Self.lateEndDrawNotice)
            #expect(!layer.warnings.hasWarned(.notDrawing), "捨てたことを言わず、beginDraw() の前と言った")
        case .emit:
            #expect(s.dust.cursor == cursor, "越えた後の emit が粒を出した")
            #expect(layer.warnings.hasWarned(.particlesOutsideFrame))
        case .force:
            #expect(s.dust.pendingForceCount == forces, "越えた後の force が力を積んだ")
            #expect(layer.warnings.hasWarned(.particlesOutsideFrame))
        case .particles:
            #expect(!layer.hasPendingComputations, "越えた後の particles(_:) が粒を進める計算を頼んだ")
            #expect(layer.warnings.hasWarned(.particlesOutsideFrame))
        case .compute:
            #expect(!layer.hasPendingComputations, "越えた後に、計算を頼めた")
            #expect(layer.warnings.hasWarned(.computeOutsideFrame))
        default:
            break
        }

        // 4 枚目: 描き場所を開き直して閉じ、本体へ置く。捨て直さない
        try main.draw {
            layer.beginDraw()
            layer.endDraw()
            main.background(black)
            main.image(layer, 0, 0)
        }
        #expect(try probes(main) == [black, black, black], "\(mouth): 捨てた後の絵に、閉じ忘れたフレームの中身が残った")
        #expect(layer.framesDrawn == 3, "\(mouth): 捨て直した、または捨てたフレームを数えていない")
        #expect(main.framesDrawn == 4)
    }

    // MARK: - 境目を越えていないものは捨てない

    @Test("同じ本体のフレームの中で読めば、閉じる前でも描いたものが読める (#1834)")
    func aLayerReadInTheSameMainFrameSeesWhatWasDrawn() throws {
        // 捨てるのは本体のフレームを越えたものだけである。同じ本体のフレームの中で読むのは、
        // 今までどおり溜めた図形を描き切って読む
        let s = try makeScene()
        let (main, layer) = (s.main, s.layer)
        var seen = LinearRGBA.transparent
        var droppedBeforeReading = true
        try main.draw {
            layer.beginDraw()
            layer.background(black)
            layer.noStroke()
            layer.fill(white)
            layer.rect(8, 8, 4, 4)
            seen = layer.get(9, 9)
            droppedBeforeReading = layer.warnings.hasWarned(.unfinishedFrameDropped)
            layer.endDraw()
        }
        #expect(seen == white, "同じ本体のフレームの中で、描いたものが読めない")
        #expect(!droppedBeforeReading)
        #expect(layer.framesDrawn == 1)
    }

    @Test("閉じ忘れを続けても、注意は 1 度で、捨てたフレームごとに番号が 1 つ進む (#1834)")
    func repeatedForgottenFramesAdvanceTheNumberOnceEach() throws {
        let s = try makeScene()
        let (main, layer) = (s.main, s.layer)
        var numbers: [Int] = []
        for _ in 0..<3 {
            try main.draw {
                numbers.append(layer.framesDrawn)
                layer.beginDraw()  // 毎フレーム開き、閉じ忘れる
                layer.rect(0, 0, 4, 4)
            }
        }
        try main.draw { numbers.append(layer.framesDrawn) }
        #expect(numbers == [0, 1, 2, 3], "捨てたフレームごとに 1 つずつ進んでいない")
        #expect(layer.warnings.message(for: .unfinishedFrameDropped) == Self.droppedAtMainFrameNotice)
        #expect(!layer.isDrawing)
    }

    @Test("draw { } で開いた描き場所は、閉包の中で本体のフレームが回っても捨てない (#1834)")
    func aLayerOpenedByDrawIsNotDroppedByTheMainFrame() throws {
        // `draw { }` が開いたフレームは、閉包を抜けるときに同じ呼び出しが閉じる。閉じ忘れうるのは
        // `beginDraw()` が開いたフレームだけである
        let s = try makeScene()
        let (main, layer) = (s.main, s.layer)
        try layer.draw {
            layer.background(black)
            layer.noStroke()
            layer.fill(white)
            layer.rect(8, 8, 4, 4)
            try? main.draw {}
            layer.rect(0, 0, 4, 4)
        }
        let image = try layer.target.readPixels()
        #expect(image[9, 9] == white, "本体のフレームの頭が、draw { } で開いたフレームを捨てた")
        #expect(image[1, 1] == white, "本体のフレームの頭が、draw { } で開いたフレームを閉じた")
        #expect(!layer.warnings.hasWarned(.unfinishedFrameDropped))
        #expect(layer.framesDrawn == 1)
    }

    @Test("作った面が居なくなった描き場所は、本体のフレームが進まないので今までどおり捨てない (#1834)")
    func aLayerWithoutItsMakerKeepsItsFrame() throws {
        // 時刻の置き場の持ち主は弱く持つ。持ち主が居なければ本体のフレームは進まないので、
        // 同じ本体のフレームの中での重ね呼びのままである
        var main: Canvas? = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        let layer = try #require(main).createGraphics(16, 16)
        main = nil
        #expect(layer.timebase.owner == nil, "検査の前提: 持ち主が居なくなっていない")
        layer.beginDraw()
        layer.background(black)
        layer.noStroke()
        layer.fill(white)
        layer.rect(8, 8, 4, 4)
        layer.beginDraw()  // 閉じ忘れて開き直す
        layer.endDraw()
        #expect(try layer.target.readPixels()[9, 9] == white)
        #expect(layer.warnings.hasWarned(.alreadyDrawing))
        #expect(!layer.warnings.hasWarned(.unfinishedFrameDropped))
    }
}
