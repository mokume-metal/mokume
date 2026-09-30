// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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

    // MARK: - 戻す (GPU を要さない)

    @Test("量子化した値は、戻して掛け直すと元の値に返る")
    func everyQuantisedLevelSurvivesTheRoundTrip() {
        // **256 段すべてを見る。** 表を引く実装が伝達関数と 1 段でも食い違えば、
        // その段で落ちる
        var bytes = [UInt8](repeating: 255, count: 256 * 4)
        for level in 0...255 {
            bytes[level * 4] = UInt8(level)
            bytes[level * 4 + 1] = UInt8(level)
            bytes[level * 4 + 2] = UInt8(level)
        }
        var pixels = [SIMD4<Float16>](repeating: .zero, count: 256)
        OutputStage.decode(DisplayImage(width: 256, height: 1, bytes: bytes), into: &pixels)

        for level in 0...255 {
            let texel = pixels[level]
            let back = OutputStage.quantize(
                OutputStage.encodeForDisplay(
                    OutputStage.straighten(Float(texel.x), alpha: Float(texel.w))))
            #expect(back == UInt8(level))
        }
    }

    @Test("戻した画素はアルファを乗算した形で入る")
    func decodingPremultipliesTheColour() {
        var pixels = [SIMD4<Float16>](repeating: .zero, count: 2)
        OutputStage.decode(
            DisplayImage(width: 2, height: 1, bytes: [255, 255, 255, 128, 0, 0, 0, 0]),
            into: &pixels)

        let alpha = Float(128) / 255
        #expect(abs(Float(pixels[0].x) - alpha) < 0.001)
        #expect(abs(Float(pixels[0].w) - alpha) < 0.001)
        // 完全に透明な画素は、色も 0 で入る
        #expect(pixels[1] == SIMD4<Float16>(0, 0, 0, 0))
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

    // MARK: - しきい値の表と減衰 (#1762)

    /// 表の段 (値以上のしきい値の数) と、正本の式 (`quantize(encodeForDisplay(x))`) の段を比べる。
    /// GPU は表との比較だけで段を決めるので、ここが一致すれば出口どうしも一致する。
    private func stepsAgree(_ linear: Float) -> Bool {
        OutputStage.quantizeThresholds.count(where: { linear >= $0 })
            == Int(OutputStage.quantize(OutputStage.encodeForDisplay(linear)))
    }

    @Test("しきい値の表は、どの境目の前後でも正本の式と同じ段を出す")
    func thresholdsMatchTheFormulaAroundEveryStep() {
        let thresholds = OutputStage.quantizeThresholds
        #expect(thresholds.count == 255)
        var disagreeing: [Float] = []
        for threshold in thresholds {
            // 境目の前後 64 ulp。**境目のほぼ真上が 1 段ずれていた所**である
            for offset in -64...64 {
                let bits = Int64(threshold.bitPattern) + Int64(offset)
                guard bits >= 0 else { continue }
                let linear = Float(bitPattern: UInt32(bits))
                if !stepsAgree(linear) { disagreeing.append(linear) }
            }
        }
        // 範囲の外と値でないもの。どちらも端の段へ落ちる
        let specials: [Float] = [
            0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, -1, 1, 1.5, 1e30,
            .infinity, -.infinity, .nan,
        ]
        for linear in specials where !stepsAgree(linear) { disagreeing.append(linear) }
        #expect(disagreeing.isEmpty, "表と式の段が違う値: \(disagreeing.prefix(8))")
    }

    @Test("しきい値の表は、0…1 のどこを取っても正本の式と同じ段を出す")
    func thresholdsMatchTheFormulaAcrossTheRange() {
        // ビット列で一様に取る (値で一様に取ると、暗い側の細かい刻みを踏まない)
        var state: UInt64 = 1762
        var disagreeing: [Float] = []
        for _ in 0..<200_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let linear = Float(bitPattern: UInt32(state >> 33) % (Float(1).bitPattern + 1))
            if !stepsAgree(linear) { disagreeing.append(linear) }
        }
        #expect(disagreeing.isEmpty, "表と式の段が違う値: \(disagreeing.prefix(8))")
    }

    @Test("減衰は、どの寄せ幅でも expf と 1 ulp 以内で一致する")
    func decayStaysWithinAnUlpOfExp() {
        var worst: Float = 0
        var worstAt: Float = 0
        // 寄せ幅は「knee を超えた分 / (1 - knee)」で、0 より大きい有限の値
        var over: Float = 0x1p-24
        while over < 20 {
            let expected = Foundation.exp(-over)
            let error = abs(Brightness.decay(over) - expected) / expected.ulp
            if error > worst { (worst, worstAt) = (error, over) }
            over = over < 1 ? over * 1.001 : over + 0x1p-12
        }
        #expect(worst <= 1, "expf との差が \(worst) ulp (寄せ幅 \(worstAt))")
        // 20 以上は 0。これまでの式でも `1 - e` は 1 に丸まっていた
        #expect(Brightness.decay(20) == 0)
        #expect(Float(1) - Foundation.exp(-Float(17.5)) == 1)
    }

    @Test("寄せた明るさは、これまでの式と 1 ulp 以内でしか動かない")
    func rolledMovesAtMostAnUlp() {
        let knee = Brightness.knee
        var worst: Float = 0
        var peak = knee.nextUp
        while peak < 64 {
            let old = knee + (1 - knee) * (1 - Foundation.exp(-((peak - knee) / (1 - knee))))
            worst = max(worst, abs(Brightness.rolled(peak) - old) / old.ulp)
            peak = peak < 2 ? Float(bitPattern: peak.bitPattern + 17) : peak + 0x1p-10
        }
        #expect(worst <= 1, "これまでの式との差が \(worst) ulp")
    }

    // MARK: - 表示できる形になった絵を読む (GPU を要さない・#1590)

    /// 幅と高さを違えた小さな絵。縦横を取り違えると範囲の判定がずれる。
    ///
    /// `nonisolated` なのは、検査の引数の並びが隔離の外で組まれるため。
    private nonisolated static let shownWidth = 3
    private nonisolated static let shownHeight = 2

    /// 位置ごとに違う**不透明な**画素。透明で埋めると、範囲の外で内側の値を返しても
    /// 透明と区別が付かず、検査が何も見なくなる。
    private static func shownPixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(10 + 40 * x), UInt8(20 + 60 * y), 128, 255)
    }

    private static func makeShownImage() -> DisplayImage {
        var bytes: [UInt8] = []
        for y in 0..<shownHeight {
            for x in 0..<shownWidth {
                let pixel = shownPixel(x, y)
                bytes += [pixel.0, pixel.1, pixel.2, pixel.3]
            }
        }
        return DisplayImage(width: shownWidth, height: shownHeight, bytes: bytes)
    }

    /// 完了条件「範囲の外で読んでも落ちず、透明 (0, 0, 0, 0) が返る」(#1590)。
    ///
    /// 4 辺のすぐ外に加えて、掛け算で溢れる大きさの位置も読む — 範囲を見る前に
    /// 置き場の位置を計算すると、そこで落ちる。
    @Test("表示できる形の絵は、範囲の外を読んでも落ちず、透明が返る", arguments: [
        (-1, 0), (shownWidth, 0), (0, -1), (0, shownHeight),
        (shownWidth, shownHeight), (Int.min, 0), (0, Int.max), (Int.max, Int.max),
    ])
    func readingOutsideTheShownImageReturnsTransparent(_ position: (Int, Int)) {
        let image = Self.makeShownImage()
        #expect(image[position.0, position.1] == (0, 0, 0, 0))
    }

    /// 範囲の端の内側は、入れた値がそのまま返る (範囲の判定が 1 つ内側へずれていない)。
    @Test("表示できる形の絵の内側の四隅は、入れた値がそのまま返る")
    func cornersInsideTheShownImageReturnWhatWasStored() {
        let image = Self.makeShownImage()
        for (x, y) in [(0, 0), (Self.shownWidth - 1, 0), (0, Self.shownHeight - 1),
                       (Self.shownWidth - 1, Self.shownHeight - 1)] {
            #expect(image[x, y] == Self.shownPixel(x, y), "(\(x), \(y))")
        }
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

    @Test(
        "行の間に詰め物がある元から拾っても、詰め物の無い元と同じ寸法とバイト列になる",
        arguments: [
            (7, 5, 4.0 / 7), (7, 5, 0.3), (9, 3, 0.5), (13, 11, 0.77), (1, 1, 0.5),
            (640, 3, 0.1), (7, 5, 1.0), (7, 5, 0.0),
        ])
    func pickingFromPaddedRowsMatchesTheTightOnes(_ size: (Int, Int, Double)) {
        let (width, height, factor) = size
        let padding = 12
        let rowStride = width * 4 + padding
        var tight = [UInt8](repeating: 0, count: width * height * 4)
        // 詰め物には目印を置く。拾う位置が行の間隔を取り違えれば、目印が紛れ込む
        var padded = [UInt8](repeating: 0xEE, count: rowStride * height)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<4 {
                    // 目印 (0xEE) と重ならないよう、0…199 に収める
                    let value = UInt8(((y * width + x) * 4 + c) % 200)
                    tight[(y * width + x) * 4 + c] = value
                    padded[y * rowStride + x * 4 + c] = value
                }
            }
        }

        let expected = NearestNeighbor.scaled(tight, width: width, height: height, by: factor)
        let picked = padded.withUnsafeBufferPointer {
            NearestNeighbor.scaled(
                rows: $0, rowStride: rowStride, width: width, height: height, by: factor)
        }
        #expect(picked?.width == expected?.width)
        #expect(picked?.height == expected?.height)
        #expect(picked?.components == expected?.components)
        #expect(picked?.components.contains(0xEE) != true, "詰め物を拾っている")
    }

    @Test("7 画素を 4 画素へ間引くと、0・1・3・5 番の画素を拾う")
    func sevenToFourPicksTheFloorOfTheScaledPosition() throws {
        let width = 7
        // 各画素の赤に自分の番号を入れる
        var row = [UInt8](repeating: 0, count: width * 4 + 8)
        for x in 0..<width { row[x * 4] = UInt8(x) }
        let picked = row.withUnsafeBufferPointer {
            NearestNeighbor.scaled(
                rows: $0, rowStride: width * 4 + 8, width: width, height: 1, by: 4.0 / 7)
        }
        let components = try #require(picked?.components)
        #expect(picked?.width == 4)
        #expect(stride(from: 0, to: components.count, by: 4).map { components[$0] } == [0, 1, 3, 5])
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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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

    /// 変換の特異点。描いた図形では踏めない値を並べる — 範囲を超えた明るさ / 負の明るさ /
    /// 完全な透明 / 乗算を戻すと 1 を超えるもの / 値になっていない成分。
    private static let edgeCases: [LinearRGBA] = [
        LinearRGBA(premultipliedRed: 4, green: 2, blue: 0, alpha: 1),
        LinearRGBA(premultipliedRed: -1, green: 0.5, blue: 0, alpha: 1),
        .transparent,
        LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5),
        LinearRGBA(premultipliedRed: .nan, green: 0.25, blue: 1, alpha: 1),
    ]

    /// 特異点を左上の行へ直に置く。**`draw` の中で呼ぶ** — 描画の区間の外で書いた画素は
    /// どのフレームにも属さず、断られる (#1672)。外で呼ぶと、比べる前の絵に特異点が
    /// 1 つも載らないまま比較が通ってしまう (#1761)。
    private func pokeEdgeCases(on canvas: Canvas) {
        for (x, color) in Self.edgeCases.enumerated() { canvas.set(x, 0, color) }
    }

    /// 特異点が実際に置かれたことを、比べる前に読み戻して確かめる。**無視された入力で
    /// 通らないため** (#1761)。有限の値は半精度に丸めた値と、値になっていない成分は
    /// `isNaN` で見る。
    private func expectEdgeCasesStored(on canvas: Canvas) throws {
        let stored = try canvas.output.readPixels()
        for (x, expected) in Self.edgeCases.enumerated() {
            let actual = stored[x, 0]
            let pairs = [
                (expected.red, actual.red), (expected.green, actual.green),
                (expected.blue, actual.blue), (expected.alpha, actual.alpha),
            ]
            for (want, got) in pairs {
                if want.isNaN {
                    #expect(got.isNaN, "(\(x), 0) に値になっていない成分が置かれていない (\(got))")
                } else {
                    #expect(got == Float(Float16(want)), "(\(x), 0) に \(want) が置かれていない (\(got))")
                }
            }
        }
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
        try canvas.draw {
            scene(on: canvas)
            pokeEdgeCases(on: canvas)
        }
        try expectEdgeCasesStored(on: canvas)

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
        try canvas.draw {
            scene(on: canvas)
            pokeEdgeCases(on: canvas)
        }
        try expectEdgeCasesStored(on: canvas)

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
        // 作業空間の原色で塗る。純色のまま 255 / 0 に出るので、どちらのフレームかを読める
        try canvas.draw { canvas.background(.linear(red: 1, green: 0, blue: 0)) }
        let first = try canvas.output.encodeToImage().read()[4, 4]

        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 1)) }
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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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

    @Test(
        "置き場から縮めて読んでも、原寸を読んでから縮めたのと同じ寸法とバイト列になる",
        arguments: [
            (48, 32, 0.5), (48, 32, 0.3), (48, 32, 0.1), (37, 23, 0.75), (37, 23, 4.0 / 7),
            (7, 5, 4.0 / 7), (7, 5, 0.2), (37, 23, 1.0), (37, 23, 1.5), (37, 23, 0.0),
        ])
    func readingScaledMatchesScalingTheFullRead(_ size: (Int, Int, Double)) throws {
        let (width, height, factor) = size
        let canvas = try makeCanvas(width: width, height: height)
        try canvas.draw { scene(on: canvas) }

        let image = try canvas.output.encodeToImage()
        // 原寸を読んでから縮める既存の計算を、独立した参照に置く
        let reference = image.read().scaled(by: factor)
        let direct = image.read(scaledBy: factor)

        #expect(direct.width == reference.width)
        #expect(direct.height == reference.height)
        #expect(direct.bytes == reference.bytes)
    }

    @Test("置き場の行に詰め物がある幅でも、縮めて読んだ絵に詰め物が紛れない")
    func readingScaledSkipsTheRowPadding() throws {
        // 幅 7 の行は 28 バイトで、置き場の整列 (#753) により詰め物が付く
        let canvas = try makeCanvas(width: 7, height: 5)
        try canvas.draw { scene(on: canvas) }
        let image = try canvas.output.encodeToImage()
        try #require(
            image.bytesPerRow > image.width * OutputPass.bytesPerPixel,
            "この機械では幅 7 の行に詰め物が付かず、この検査の前提が立たない")

        let reference = image.read().scaled(by: 0.6)
        #expect(image.read(scaledBy: 0.6).bytes == reference.bytes)
    }

    @Test("縮めて読んだ絵は、次のフレームを描いても変わらない")
    func aScaledReadIsNotOverwrittenByTheNextFrame() throws {
        let canvas = try makeCanvas()
        try canvas.draw { canvas.background(.linear(red: 1, green: 0, blue: 0)) }
        let first = try canvas.output.encodeToImage().read(scaledBy: 0.5)
        let kept = first.bytes

        // 置き場は使い回される 1 枚なので、写さずに参照していれば青へ変わる
        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 1)) }
        let second = try canvas.output.encodeToImage().read(scaledBy: 0.5)

        #expect(first.bytes == kept)
        #expect(first[0, 0].red == 255 && first[0, 0].blue == 0)
        #expect(second[0, 0].red == 0 && second[0, 0].blue == 255)
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
