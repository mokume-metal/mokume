// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 同期で読む出口 (``RenderTarget/encodeForDisplay(scale:)``・``RenderTarget/writePNG(to:)``) は
/// GPU の出力段を通る (#1752)。答えは CPU の参照と同じで、出口へ渡す絵を書き換えず、待てなければ
/// 投げる。
@Suite(
    "出力段: 同期で読む出口",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct DisplayOutputTests {
    // MARK: - 縮小寸法

    /// 行の詰め物が要る幅・縦長・1 画素を混ぜる。
    nonisolated static let sizes: [(width: Int, height: Int)] = [(1, 1), (641, 37), (37, 641), (64, 48)]

    /// 縮める倍率と、縮めない倍率 (1 以上・0・負) を混ぜる。
    static let scales: [Double] = [0.5, 0.37, 0.01, 1, 2, 0, -1]

    @Test("縮小の寸法でも、同期で読む出口が CPU の参照と同じバイトを出す", arguments: sizes.indices)
    func scaledReadsMatchTheReference(sizeIndex: Int) throws {
        let (width, height) = Self.sizes[sizeIndex]
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        var random = OutputSplitMix(seed: UInt64(1752 + sizeIndex))
        try canvas.draw {
            for y in 0..<height {
                for x in 0..<width {
                    canvas.set(
                        x, y,
                        LinearRGBA(
                            premultipliedRed: random.component(), green: random.component(),
                            blue: random.component(), alpha: random.alpha()))
                }
            }
        }

        var reports: [String] = []
        for (exposure, toneMapping) in [(Float(1), ToneMapping.clip), (1.37, .roll)] {
            canvas.exposure(exposure)
            canvas.toneMapping(toneMapping)
            for scale in Self.scales {
                let shown = try canvas.output.encodeForDisplay(scale: scale)
                let reference = try canvas.output.encodeOnCPU(scale: scale)
                if shown.width != reference.width || shown.height != reference.height
                    || shown.bytes != reference.bytes
                {
                    reports.append(
                        "\(width)×\(height) 倍率 \(scale) \(toneMapping): 出口 \(shown.width)×\(shown.height) / 参照 \(reference.width)×\(reference.height)")
                }
            }
        }
        #expect(reports.isEmpty, "\(reports.joined(separator: "\n"))")
    }

    // MARK: - 出口へ渡す絵を書き換えない

    @Test("出口へ渡す絵を持ったまま同期で読んでも、持っている絵は書き換わらない")
    func readingDoesNotOverwriteTheTakenImage() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        // 作業空間の原色で塗る。純色のまま 255 / 0 に出るので、どちらの絵かを読める
        try canvas.draw { canvas.background(.linear(red: 1, green: 0, blue: 0)) }
        // 出口へ渡すのは次のフレームの頭で、それまでランタイムはこの 1 枚を控えている (#927)
        let taken = try canvas.output.encodeToImage()

        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 1)) }
        let shown = try canvas.output.encodeForDisplay()[4, 4]

        #expect(shown.red == 0 && shown.blue == 255, "同期で読んだ絵がいまのフレームでない")
        let held = taken.read()[4, 4]
        #expect(held.red == 255 && held.blue == 0, "同期の読み出しが、出口へ渡す絵を書き換えた")
    }

    /// 白と黒をフレームごとに交互に塗るスケッチ。出口へ渡す絵がどのフレームのものかを読める。
    final class AlternatingSketch: Sketch {
        nonisolated(unsafe) static var declared: [any Outlet] = []

        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        var plugins: [any Plugin] { [OutletPlugin(outlets: Self.declared)] }

        /// フレーム `frame` で塗る明るさ (8 bit)。偶数フレームが白。
        static func level(atFrame frame: Int) -> UInt8 { frame % 2 == 0 ? 255 : 0 }

        func draw() { background(Double(Self.level(atFrame: frameCount))) }
    }

    struct OutletPlugin: Plugin {
        let outlets: [any Outlet]
        func register(into registry: PluginRegistry) {
            for outlet in outlets { registry.add(outlet: outlet) }
        }
    }

    /// 受け取ったフレームの番号と、左上の明るさを覚える出口。
    final class WatchingOutlet: Outlet {
        private(set) var frames: [(frame: Int, level: UInt8)] = []

        func receive(_ frame: OutputFrame) {
            frames.append((frame.frame, frame.bytes()[0, 0].0))
        }
    }

    @Test("フレームの合間に同期で読んでも、出口へ届く絵の番号・中身・順序は変わらない")
    func readingBetweenFramesKeepsTheOutletStream() throws {
        let outlet = WatchingOutlet()
        AlternatingSketch.declared = [outlet]
        let runtime = try SketchRuntime(sketch: AlternatingSketch(), gpu: RenderDevice())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var shownLevels: [UInt8] = []
        for frame in 1...4 {
            try runtime.advance()
            // **控えと違う絵を同期で読む。** 露出を 0 にすると白も黒に出るので、同期の読み出しが
            // 控えと同じ置き場へ組めば、次のフレームの頭で出口へ黒が届く
            runtime.target.brightness.exposure = 0
            shownLevels.append(try runtime.target.encodeForDisplay()[0, 0].red)
            try runtime.target.writePNG(to: directory.appendingPathComponent("\(frame).png"))
            runtime.target.brightness.exposure = 1
        }
        runtime.closePlugins()

        #expect(shownLevels == [0, 0, 0, 0], "露出 0 の同期の読み出しに光が出ている")
        #expect(outlet.frames.map(\.frame) == [1, 2, 3, 4], "出口へ届く番号・順序が変わった")
        for received in outlet.frames {
            #expect(
                received.level == AlternatingSketch.level(atFrame: received.frame),
                "\(received.frame) 枚目の絵が、合間の同期の読み出しで書き換わった")
        }
        // 同期の読み出しは「出口へ渡す道」を通った回数に数えない (出口が無ければ 0 回、の目印)
        #expect(runtime.target.encodePassCount == 4)
        for frame in 1...4 {
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("\(frame).png").path))
        }
    }

    // MARK: - 待てなければ投げる

    @Test("GPU を待てなければ同期の読み出しは投げ、前に組んだ絵を返さない")
    func failingToWaitThrowsInsteadOfReturningAnOldImage() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
        try canvas.draw { canvas.background(.linear(red: 1, green: 0, blue: 0)) }
        // 置き場に赤の絵を残しておく。待てずに読めば、これが成功として返る
        _ = try canvas.output.encodeForDisplay()

        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 1)) }
        let failure = RenderFailure.timedOut(seconds: RenderDevice.waitLimitSeconds)
        gpu.failSettleForTesting = failure
        #expect(throws: failure) { _ = try canvas.output.encodeForDisplay() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-display-\(UUID().uuidString).png")
        #expect(throws: failure) { try canvas.output.writePNG(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "待てなかったのに書き出した")

        gpu.failSettleForTesting = nil
        let recovered = try canvas.output.encodeForDisplay()[4, 4]
        #expect(recovered.red == 0 && recovered.blue == 255, "直った後の読み出しがいまのフレームでない")
    }
}
