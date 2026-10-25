// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 画素の写しの有効性は、**その面への書き込み**で決まる ([#2786])。
///
/// かつては土台の投入の通し番号と比べていたので、同じ ``RenderDevice`` の別の面 B が動くたびに、
/// 静止した面 A の写しが無効になり、A の全面を読み戻し直していた。ここは 2 つの向きを見る:
///
/// - B がどう動いても、A へ書かない間は A を読み戻し直さない (省いた分)
/// - A へ書く投入は、B が動いていても次の読みに必ず出る (守る分。見落とすと古い絵が読める)
///
/// [#2786]: https://github.com/mokume-metal/mokume/issues/2786
@Suite(
    "画素の写しの有効性(面ごと)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MirrorValidityPerSurfaceTests {
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// A とは別の面を動かす方法。**どれも A には書かない。**
    enum Movement: CaseIterable, CustomTestStringConvertible {
        /// B を塗り直す。
        case fill
        /// B を読み戻す (投入が 1 本増える)。
        case readBack
        /// B の描き切り (図形の上げ・描画・投入)。
        case draw
        /// B に A を貼る。A は読まれるだけである。
        case placeA

        var testDescription: String {
            switch self {
            case .fill: "B を塗り直す"
            case .readBack: "B を読み戻す"
            case .draw: "B を描く"
            case .placeA: "B へ A を貼る"
            }
        }
    }

    private struct Pair {
        let gpu: RenderDevice
        let a: Canvas
        let b: Canvas
    }

    private func makePair() throws -> Pair {
        let gpu = try RenderDevice()
        return Pair(
            gpu: gpu,
            a: try CanvasFixture.make(gpu: gpu, width: 16, height: 16),
            b: try CanvasFixture.make(gpu: gpu, width: 8, height: 8))
    }

    /// B を 1 回動かして、GPU の完了まで待つ (A を読む計測区間には入れない)。
    private func move(_ movement: Movement, _ pair: Pair, round: Int) throws {
        let color = round.isMultiple(of: 2) ? red : blue
        switch movement {
        case .fill:
            try pair.b.target.fill(with: color)
        case .readBack:
            _ = try pair.b.target.readPixels()
        case .draw:
            try pair.b.draw {
                pair.b.background(color)
                pair.b.noStroke()
                pair.b.fill(green)
                pair.b.rect(0, 0, 4, 4)
            }
        case .placeA:
            try pair.b.draw {
                pair.b.background(color)
                pair.b.image(pair.a, 0, 0)
            }
        }
        try pair.gpu.settle()
    }

    private func paintA(_ pair: Pair, _ color: LinearRGBA) throws {
        try pair.a.draw { pair.a.background(color) }
    }

    // MARK: - 省く向き

    /// 完了条件 1 — A を読んだ後、B がどう動いても、A の読み戻しは増えず、返す画素は変わらない。
    @Test("別の面が動いても、静止した面は読み戻し直さない", arguments: Movement.allCases)
    func aStillSurfaceIsNotReadBackWhileAnotherMoves(movement: Movement) throws {
        let pair = try makePair()
        try paintA(pair, red)
        let reference = try pair.a.target.readPixels()
        let readbacks = pair.a.target.pixelReadbacksEncoded
        let mirrors = pair.a.target.pixelMirrorsMade
        try #require(readbacks >= 1, "検査の前提: 最初の読みが読み戻している")

        for round in 0..<28 {
            try move(movement, pair, round: round)
            let read = try pair.a.target.readPixels()
            #expect(read == reference, "\(round) 回目: 静止した面の画素が変わった")
        }
        #expect(
            pair.a.target.pixelReadbacksEncoded == readbacks,
            "別の面の投入で、静止した面を \(pair.a.target.pixelReadbacksEncoded - readbacks) 回読み戻し直した")
        #expect(pair.a.target.pixelMirrorsMade == mirrors, "写しを作り直した")
    }

    /// 画素の窓 (`pixels`・#2956) も同じ式で決める。窓の取り直しが、別の面の投入で読み戻しを呼ばない。
    @Test("別の面が動いても、窓越しに静止した面を読み戻し直さない")
    func theWindowIsNotRefilledWhileAnotherSurfaceMoves() throws {
        let pair = try makePair()
        try paintA(pair, red)
        try #require(pair.a.target.pixels[3, 3] == red)
        let readbacks = pair.a.target.pixelReadbacksEncoded

        for round in 0..<28 {
            try move(.draw, pair, round: round)
            #expect(pair.a.target.pixels[3, 3] == red, "\(round) 回目: 窓が違う画素を返した")
        }
        #expect(pair.a.target.pixelReadbacksEncoded == readbacks, "窓の取り直しで読み戻し直した")
    }

    // MARK: - 守る向き

    /// A へ書く経路。**どれも、B が動いている最中でも次の読みに新しい内容が出る。**
    enum Write: CaseIterable, CustomTestStringConvertible {
        /// 面を直に塗る。
        case fill
        /// 描き切りで背景を塗る。
        case draw
        /// CPU の画素の書き込み (フレームの終わりに書き戻す)。
        case pixelSet
        /// 効果 (周辺減光) を掛ける。
        case effect

        var testDescription: String {
            switch self {
            case .fill: "fill"
            case .draw: "描き切り"
            case .pixelSet: "CPU の画素の書き込み"
            case .effect: "効果"
            }
        }
    }

    @Test("A へ書く投入は、別の面が動いていても次の読みに出る", arguments: Write.allCases)
    func aWriteToTheSurfaceShowsInTheNextRead(write: Write) throws {
        let pair = try makePair()
        try paintA(pair, red)
        let before = try pair.a.target.readPixels()
        let readbacks = pair.a.target.pixelReadbacksEncoded
        try move(.draw, pair, round: 0)

        switch write {
        case .fill:
            try pair.a.target.fill(with: green)
        case .draw:
            try pair.a.draw { pair.a.background(green) }
        case .pixelSet:
            try pair.a.draw { pair.a.set(5, 5, green) }
        case .effect:
            try pair.a.draw { pair.a.effects([.vignette(amount: 1)]) }
        }
        try move(.draw, pair, round: 1)

        let after = try pair.a.target.readPixels()
        #expect(after != before, "A へ書いたのに、読み直しても同じ画素が返った (古い写し)")
        switch write {
        case .fill, .draw: #expect(after[8, 8] == green)
        case .pixelSet:
            #expect(after[5, 5] == green)
            #expect(after[8, 8] == red, "書いていない画素が変わった")
        case .effect: #expect(after[0, 0] != before[0, 0], "効果が角の画素に出ていない")
        }
        #expect(pair.a.target.pixelReadbacksEncoded > readbacks, "新しい内容を読み戻していない")
        // 続けて読めば、もう読み戻さない
        let settled = pair.a.target.pixelReadbacksEncoded
        for round in 2..<6 {
            try move(.fill, pair, round: round)
            #expect(try pair.a.target.readPixels() == after)
        }
        #expect(pair.a.target.pixelReadbacksEncoded == settled)
    }

    /// 出す先が描く先と別の面 (細かさを下げた面) では、拡大も出す先への書き込みである。
    @Test("拡大された出力は、別の面が動いていても次の読みに新しい内容が出る")
    func anUpscaledOutputShowsTheNextRead() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 32, height: 32)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        let other = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        try canvas.draw { canvas.background(red) }
        try #require(try canvas.output.readPixels()[16, 16] == red)
        let readbacks = canvas.output.pixelReadbacksEncoded

        for round in 0..<5 {
            try other.draw { other.background(round.isMultiple(of: 2) ? blue : black) }
            #expect(try canvas.output.readPixels()[16, 16] == red)
        }
        #expect(canvas.output.pixelReadbacksEncoded == readbacks, "別の面の投入で出力を読み戻し直した")

        try canvas.draw { canvas.background(green) }
        try other.draw { other.background(blue) }
        #expect(try canvas.output.readPixels()[16, 16] == green, "拡大した出力に新しい絵が出ていない")
        #expect(canvas.output.pixelReadbacksEncoded > readbacks)
    }

    /// 打ち切られた書き込みも面の書き込みである。古い写しを成功として返さない。
    @Test("A への書き込みを GPU が打ち切ったら、古い写しを成功として返さない")
    func aDroppedWriteIsNotAnsweredWithAStaleMirror() throws {
        let pair = try makePair()
        try paintA(pair, red)
        _ = try pair.a.target.readPixels()
        try move(.draw, pair, round: 0)

        pair.gpu.dropsNextSubmissionForTesting = "dropped for the test"
        try pair.a.target.fill(with: green)
        try pair.gpu.settle()
        #expect(throws: RenderFailure.self) { _ = try pair.a.target.readPixels() }
    }
}
