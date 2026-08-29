// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("出力段")
struct OutputStageTests {
    // MARK: - 手ごとの検査 (GPU を要さない)

    @Test("0 と 1 は端に落ちる")
    func endpointsMapToEnds() {
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(0)) == 0)
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(1)) == 255)
    }

    @Test("線形の中間値は、伝達関数を経て明るい側へ寄る")
    func midtoneIsEncoded() {
        // 線形 0.5 は sRGB の伝達関数で約 0.7354 → 188。
        // 伝達関数を掛け忘れると 128 になるので、この 1 点で掛け忘れが分かる。
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(0.5)) == 188)
    }

    @Test("伝達関数の折れ目の下は直線")
    func lowEndIsLinearSegment() {
        // 0.0031308 以下は 12.92 倍の直線。曲線側の式をそのまま使うと暗部が
        // 持ち上がるので、折れ目を持っていることを傾きで確かめる。
        let first = OutputStage.encodeForDisplay(0.001)
        let second = OutputStage.encodeForDisplay(0.002)
        #expect(abs(first - 12.92 * 0.001) < 1e-6)
        #expect(abs((second - first) / 0.001 - 12.92) < 1e-3)
    }

    @Test("標準レンジの外側は端へ寄せる")
    func outOfRangeIsClamped() {
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(4)) == 255)
        #expect(OutputStage.quantize(OutputStage.encodeForDisplay(-0.25)) == 0)
    }

    @Test("標準レンジの内側は曲げない")
    func insideStandardRangeIsUntouched() {
        // ここを曲線で圧縮すると、指定した色がそのまま出るという前提が崩れる
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            #expect(OutputStage.clampToStandardRange(value) == value)
        }
    }

    @Test("アルファの乗算を戻す")
    func alphaIsStraightenedAtTheBoundary() {
        // 半透明の白は作業空間では (0.5, 0.5, 0.5, 0.5) として運ばれる。
        // 戻さずに書き出すと灰色になる。
        let pixels = PixelBuffer(width: 1, height: 1, components: [0.5, 0.5, 0.5, 0.5])
        let image = OutputStage.encode(pixels)
        #expect(image[0, 0].red == 255)
        #expect(image[0, 0].alpha == 128)
    }

    @Test("完全に透明な画素は成分も 0")
    func fullyTransparentHasNoColor() {
        let pixels = PixelBuffer(width: 1, height: 1, components: [0, 0, 0, 0])
        let image = OutputStage.encode(pixels)
        #expect(image[0, 0] == (0, 0, 0, 0))
    }

    @Test("値になっていない成分は 0 へ倒す")
    func notANumberFallsToZero() {
        // 比較がすべて false になるので、範囲へ収める処理が素通ししやすい
        #expect(OutputStage.clampToStandardRange(.nan) == 0)
        #expect(OutputStage.quantize(.nan) == 0)
    }

    // MARK: - 間引きは出力段の前で効く (#382)

    /// 特異な値を含む作業空間の画素を組む。
    ///
    /// 左上には**変換の特異点を集める** — 値になっていない成分・範囲を超えた明るさ・
    /// 負の明るさ。ここは間引きの倍率によらず必ず拾われる位置なので、どの倍率でも
    /// 特異点が照合に載る。残りは半透明と範囲外を混ぜて埋める。
    private func makeVariedPixels(width: Int, height: Int) -> PixelBuffer {
        var components = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let alpha = Float16(Double(index % 5) / 4)
                let tone = Float16(Double(index) / Double(width * height))
                let base = index * 4
                components[base] = tone * alpha
                components[base + 1] = (1 - tone) * alpha
                // 乗算を戻すと 1 を超えるものを混ぜる (範囲へ収める手を通す)
                components[base + 2] = 2 * tone * alpha
                components[base + 3] = alpha
            }
        }
        components[0] = .nan
        components[1] = 4
        components[2] = -1
        components[3] = 1
        return PixelBuffer(width: width, height: height, components: components)
    }

    @Test(
        "間引いてから変換しても、変換してから間引いたのと同じバイト列になる",
        arguments: [0.5, 0.3, 0.75, 0.1])
    func decimatingBeforeEncodingGivesTheSameBytes(factor: Double) {
        let pixels = makeVariedPixels(width: 7, height: 5)
        // 変換してから間引いた側。オラクルはここが持つ — 生産側に間引きの実装を
        // 2 つ置くと「同じ点を拾う」が二重管理になる
        let full = OutputStage.encode(pixels)
        let small = OutputStage.encode(pixels.scaled(by: factor))

        #expect(small.width == max(1, Int((7 * factor).rounded())))
        #expect(small.height == max(1, Int((5 * factor).rounded())))
        for y in 0..<small.height {
            for x in 0..<small.width {
                let sourceX = min(full.width - 1, x * full.width / small.width)
                let sourceY = min(full.height - 1, y * full.height / small.height)
                #expect(
                    small[x, y] == full[sourceX, sourceY],
                    "(\(x), \(y)) が元の (\(sourceX), \(sourceY)) と違う")
            }
        }
    }

    /// 完了条件「出力段が受け取る画素数が、要求した `scale` の画素数と一致する」。
    ///
    /// 出力段の費用は画素数にそのまま比例するので、**渡す前に減っていること**が
    /// 捨てるぶんを変換していないことにあたる。この画素を出力段へ渡す唯一の場所が
    /// `RenderTarget.encodeForDisplay(scale:)` である。
    @Test("間引いた画素の数は、要求した倍率のぶんしかない")
    func onlyTheRequestedPixelsReachTheOutputStage() {
        let pixels = makeVariedPixels(width: 960, height: 540)
        let small = pixels.scaled(by: 0.5)
        #expect(small.width == 480)
        #expect(small.height == 270)
        #expect(small.components.count == small.width * small.height * 4)
        // 実寸の 4 分の 1 — 出力段の費用もここまで落ちる
        #expect(small.width * small.height == pixels.width * pixels.height / 4)
    }

    @Test("倍率が範囲の外なら実寸のまま返す", arguments: [1.0, 1.5, 0.0, -0.5])
    func factorsOutsideTheRangeLeaveThePixelsAlone(factor: Double) {
        let pixels = makeVariedPixels(width: 7, height: 5)
        let same = pixels.scaled(by: factor)
        #expect(same.width == pixels.width)
        #expect(same.height == pixels.height)
        // 値になっていない成分は自分自身とも等しくならないので、ビット列で比べる
        #expect(same.components.map(\.bitPattern) == pixels.components.map(\.bitPattern))
    }
}

/// 面に描かずに取り出す道 (#440)。GPU を要する。
///
/// [ADR-0024] 決定 6 は「出力段を通した絵を、画面の面へ描くパスから独立して取り出す
/// 道が 1 本あること」と「全ての出口がそこから受け取ること」を要求する。ここが見るのは
/// **取り出した絵が、読み戻して変換した絵と同じであること** — 違えば、外から足した
/// 出口でだけ [ADR-0023] 決定 2 (出口の一致) が破れる。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
@Suite(
    "出力段: 面に描かずに取り出す",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OutputEncodeTests {
    private func makeCanvas(width: Int = 48, height: Int = 32) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 出力段の 4 手を全部踏ませる絵を描く。
    ///
    /// **不透明な色だけでは足りない。** 乗算を戻す手と範囲へ収める手は、半透明と
    /// 範囲外の明るさが無いと通らない — 通らない手は、実装が抜けていても一致する。
    private func scene(on canvas: Canvas) {
        canvas.background(.display(red: 0.02, green: 0.03, blue: 0.06))
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.3))
        canvas.circle(16, 16, 12)
        // 半透明 — 乗算を戻す手が要る
        canvas.fill(.display(red: 0.2, green: 0.5, blue: 1, alpha: 0.4))
        canvas.rect(20, 8, 20, 18)
    }

    /// 変換の特異点を直に置く。描いた図形では踏めない値を並べる。
    private func pokeEdgeCases(on canvas: Canvas) {
        // 範囲を超えた明るさ / 負の明るさ / 完全な透明 / 乗算を戻すと 1 を超えるもの
        canvas.set(0, 0, LinearRGBA(premultipliedRed: 4, green: 2, blue: 0, alpha: 1))
        canvas.set(1, 0, LinearRGBA(premultipliedRed: -1, green: 0.5, blue: 0, alpha: 1))
        canvas.set(2, 0, .transparent)
        canvas.set(3, 0, LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
        canvas.set(4, 0, LinearRGBA(premultipliedRed: .nan, green: 0.25, blue: 1, alpha: 1))
    }

    /// 2 つの絵を画素ごとに比べる。
    ///
    /// **食い違った数だけでなく、最初の 1 つの中身まで返す。** 数と最大の差だけでは
    /// 「全体がわずかにずれている」のか「特定の値だけが違う」のかが分かれず、原因の
    /// 見当が付かない。
    private func compare(_ taken: DisplayImage, _ readBack: DisplayImage) -> Comparison {
        var result = Comparison()
        for y in 0..<taken.height {
            for x in 0..<taken.width {
                let a = taken[x, y]
                let b = readBack[x, y]
                guard a != b else { continue }
                result.mismatches += 1
                if result.detail == nil { result.detail = "(\(x), \(y)) 取り出し \(a) / 読み戻し \(b)" }
                result.worst = max(
                    result.worst,
                    max(
                        max(abs(Int(a.red) - Int(b.red)), abs(Int(a.green) - Int(b.green))),
                        max(
                            abs(Int(a.blue) - Int(b.blue)),
                            abs(Int(a.alpha) - Int(b.alpha)))))
            }
        }
        return result
    }

    private struct Comparison {
        var mismatches = 0
        var worst = 0
        var detail: String?

        /// 失敗のときに読む 1 行。
        var report: String {
            "\(mismatches) 画素が食い違う (最大の差 \(worst))。最初は \(detail ?? "-")"
        }
    }

    @Test("取り出した絵が、読み戻して変換した絵と画素で一致する")
    func takenImageMatchesTheReadBackOne() throws {
        let canvas = try makeCanvas()
        try canvas.draw { scene(on: canvas) }
        pokeEdgeCases(on: canvas)

        let taken = try canvas.output.encodeToImage().read()
        let readBack = try canvas.output.encodeForDisplay()

        #expect(taken.width == readBack.width)
        #expect(taken.height == readBack.height)
        let result = compare(taken, readBack)
        #expect(result.mismatches == 0, "\(result.report)")
    }

    @Test(
        "明るさを写す設定を変えても一致する",
        arguments: [
            (Float(1), ToneMapping.roll), (2, .clip), (2, .roll), (0.5, .roll),
        ])
    func takenImageMatchesUnderEveryBrightness(exposure: Float, toneMapping: ToneMapping) throws {
        let canvas = try makeCanvas()
        canvas.exposure(exposure)
        canvas.toneMapping(toneMapping)
        try canvas.draw { scene(on: canvas) }
        pokeEdgeCases(on: canvas)

        let result = compare(
            try canvas.output.encodeToImage().read(), try canvas.output.encodeForDisplay())
        #expect(result.mismatches == 0, "露出 \(exposure) / 丸め \(toneMapping): \(result.report)")
    }

    @Test("何度取り出しても、置き場は 1 枚のまま")
    func repeatedTakesReuseTheSameStorage() throws {
        let canvas = try makeCanvas()
        // 頼まれるまでは 1 枚も作らない (出口の無いスケッチは何も払わない)
        #expect(canvas.output.encodedImagesMade == 0)

        for _ in 0..<24 {
            try canvas.draw { scene(on: canvas) }
            _ = try canvas.output.encodeToImage()
        }
        // フレームごとに確保していれば 24 になる (ADR-0023 決定 5)
        #expect(canvas.output.encodedImagesMade == 1)
    }

    @Test("取り出した絵は、いまのフレームのもの")
    func takenImageFollowsTheLatestFrame() throws {
        let canvas = try makeCanvas()
        try canvas.draw { canvas.background(.display(red: 1, green: 0, blue: 0)) }
        let first = try canvas.output.encodeToImage().read()[4, 4]

        try canvas.draw { canvas.background(.display(red: 0, green: 0, blue: 1)) }
        let second = try canvas.output.encodeToImage().read()[4, 4]

        // 使い回している 1 枚を返すので、古い中身が残っていると 2 回目が赤のままになる
        #expect(first.red == 255 && first.blue == 0)
        #expect(second.red == 0 && second.blue == 255)
    }
}

/// 観測が通る道 (#448)。GPU を要する。
///
/// 観測は出口が受け取るのと同じ道を通り、小さくするのは通した後で行う。
/// **拾う画素が同じなら、間引く位置を変えてもバイト列は変わらない** (#382 の逆向き)。
@Suite(
    "出力段: 観測の道",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ObservationRoadTests {
    private func makeCanvas(width: Int = 48, height: Int = 32) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 明暗と半透明が混ざった絵。**一様な色では間引きの違いが出ない。**
    private func scene(on canvas: Canvas) {
        canvas.background(.display(red: 0.02, green: 0.03, blue: 0.06))
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.3))
        canvas.circle(16, 16, 12)
        canvas.fill(.display(red: 0.2, green: 0.5, blue: 1, alpha: 0.4))
        canvas.rect(20, 8, 20, 18)
    }

    @Test(
        "道を通してから間引いても、間引いてから読み戻したのと同じバイト列になる",
        arguments: [1.0, 0.5, 0.3, 0.75, 0.1])
    func scalingAfterTheRoadMatchesScalingBefore(factor: Double) throws {
        let canvas = try makeCanvas()
        try canvas.draw { scene(on: canvas) }

        // 道を通してから間引いた側 (観測がこれから通る経路)
        let viaRoad = try canvas.output.encodeToImage().read().scaled(by: factor)
        // 間引いてから読み戻して変換した側 (これまでの経路・オラクル)
        let viaReadback = try canvas.output.encodeForDisplay(scale: factor)

        #expect(viaRoad.width == viaReadback.width)
        #expect(viaRoad.height == viaReadback.height)
        #expect(viaRoad.bytes == viaReadback.bytes)
    }

    @Test("縮小率が範囲の外なら実寸のまま返す", arguments: [1.0, 1.5, 0.0, -0.5])
    func factorsOutsideTheRangeLeaveTheImageAlone(factor: Double) throws {
        let canvas = try makeCanvas()
        try canvas.draw { scene(on: canvas) }
        let full = try canvas.output.encodeToImage().read()
        let same = full.scaled(by: factor)

        #expect(same.width == full.width)
        #expect(same.height == full.height)
        #expect(same.bytes == full.bytes)
    }
}
