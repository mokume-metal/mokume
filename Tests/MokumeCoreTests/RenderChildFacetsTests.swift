// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 書き出しの子 (`MOKUME_RENDER`) は、利用者の区画 `observe` / `input` / `params` が在っても開かない
/// ([#1619](https://github.com/mokume-metal/mokume/issues/1619)・ADR-0032「書き出す起こし方」)。
///
/// 開くと、外から届く入力とつまみの値が書き出しに混ざり (同じ引数から同じ動きが出ない・水準 2)、
/// 見張りの目録 (`params/report.json`) も起動しただけで書き換わる。**保存された値は区画と別の口なので、
/// 開かなくても戻る。**
///
/// ## 区画は本番と同じ場所に置く
///
/// 既定引数が見る場所そのもの (`WorkDirectory.facet(_:)`) に置く (`LaunchedByToolTests` と同じ理由。
/// 直に渡すと、本番の場所を見る口が検査では一度も開かない)。**1 本ずつ走らせる** — 区画も
/// プロセスで 1 つなので、並べると互いの置いたものを見る。
@Suite(
    "書き出しの子は、利用者の区画を開かない",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct RenderChildFacetsTests {
    /// つまみを 1 つ持ち、`setup()` と各 `draw()` で見えた値を控えるスケッチ。
    private final class Tuned: Sketch {
        @Param(0...1) var gain: Double = 0.5
        var gainAtSetup: Double?
        var gainsInDraw: [Double] = []
        var settings: SketchSettings { SketchSettings(width: 32, height: 16, frameRate: 60) }
        func setup() { gainAtSetup = gain }
        func draw() {
            gainsInDraw.append(gain)
            background(0)
        }
    }

    private static let sentinel = #"{"sentinel":"the watcher's catalogue"}"#
    private static let observeRequest = #"{"id":"o1"}"#
    private static let inputRequest =
        #"{"id":"i1","events":[{"type":"mouseMoved","x":5,"y":6}]}"#
    private static let paramsRequest =
        #"{"id":"p1","values":[{"name":"gain","type":"float","value":0.9}]}"#
    private static let savedGain = #"{"values":[{"name":"gain","type":"float","value":0.25}]}"#

    /// 触る場所: 3 つの区画と、保存の置き場。
    private static var places: [URL] {
        // `state` は区画ではなく `.mokume/state` (`WorkDirectory.state`)
        ["observe", "input", "params"].map { WorkDirectory.facet($0) } + [WorkDirectory.state]
    }

    /// 本番と同じ場所に 3 つの区画と保存を置いて本体を走らせ、終わったら元へ戻す。
    /// **手元に元から在ったものは退かせて戻す。**
    private func withProductionFacets<T>(_ body: () throws -> T) throws -> T {
        let manager = FileManager.default
        let root = WorkDirectory.root
        let hadRoot = WorkDirectory.directoryExists(at: root)
        var aside: [(URL, URL)] = []
        for place in Self.places where WorkDirectory.directoryExists(at: place) {
            let moved = root.appendingPathComponent("aside-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: place, to: moved)
            aside.append((place, moved))
        }
        defer {
            for place in Self.places { try? manager.removeItem(at: place) }
            for (place, moved) in aside { try? manager.moveItem(at: moved, to: place) }
            if !hadRoot, (try? manager.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
                try? manager.removeItem(at: root)
            }
        }
        for place in Self.places { try manager.createDirectory(at: place, withIntermediateDirectories: true) }
        func put(_ text: String, _ name: String, in place: URL) throws {
            try Data(text.utf8).write(to: place.appendingPathComponent(name))
        }
        try put(Self.observeRequest, "request.json", in: WorkDirectory.facet("observe"))
        try put(Self.inputRequest, "request.json", in: WorkDirectory.facet("input"))
        try put(Self.paramsRequest, "request.json", in: WorkDirectory.facet("params"))
        try put(Self.sentinel, "report.json", in: WorkDirectory.facet("params"))
        try put(Self.savedGain, "params.json", in: WorkDirectory.state)
        return try body()
    }

    private func contents(_ name: String, in key: String) -> String? {
        try? String(
            contentsOf: WorkDirectory.facet(key).appendingPathComponent(name), encoding: .utf8)
    }

    /// 書き出しの経路を、本番と同じ入口 (`SketchApplication`・既定の場所) で最後まで走らせる。
    private func render(_ sketch: Tuned, frames: Int) throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-facets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let request = try #require(
            RenderRequest(
                frameRate: 30, frameCount: frames,
                destination: output.appendingPathComponent("f-####.png").path))
        let application = try SketchApplication(
            sketch: sketch, gpu: RenderDevice(), render: request)
        var reply: NSApplication.TerminateReply?
        var replied = false
        application.onRenderFinished = { [weak application] in reply = application?.shouldTerminate() }
        application.onStopSignal = { [weak application] in reply = application?.shouldTerminate() }
        application.replyToTermination = { replied = true }
        application.exitProcess = { Issue.record("書き出しが 0 以外で終わった: \($0)") }
        application.resolveOutlet()
        application.didFinishLaunching()
        for _ in 0..<(frames * 2) { application.displayLinkFired() }
        if reply == .terminateLater {
            let deadline = DispatchTime.now() + 60
            while !replied, DispatchTime.now() < deadline {
                application.pollTermination()
                if !replied { Thread.sleep(forTimeInterval: 0.005) }
            }
            try #require(replied, "60 秒待っても後始末が済まない")
        }
        application.willTerminate()
        let written = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasSuffix(".png") }
        #expect(written.count == frames, "\(frames) 枚を頼んで \(written.count) 枚")
    }

    @Test("区画に要求と目録が在っても、書き出しの子は何も読まず、何も書き換えず、錠も取らない")
    func renderingLeavesTheFacetsAlone() throws {
        try withProductionFacets {
            let sketch = Tuned()
            try render(sketch, frames: 3)

            // 要求は誰にも応えられない (応えれば応答が書かれる)
            #expect(contents("report.json", in: "observe") == nil, "観測の要求に応えた")
            #expect(contents("report.json", in: "input") == nil, "入力の要求に応えた")
            // 見張りの目録は、起動しただけでは書き換わらない
            #expect(
                contents("report.json", in: "params") == Self.sentinel, "つまみの目録を書き換えた")
            // 区画の権利を取っていない
            for key in ["observe", "input", "params"] {
                let claim = WorkDirectory.claimURL(under: WorkDirectory.facet(key))
                #expect(!FileManager.default.fileExists(atPath: claim.path), "\(key) の錠を取った")
            }
            // 外から書かれたつまみの値 (0.9) は、書き出しに混ざらない
            #expect(!sketch.gainsInDraw.isEmpty)
            #expect(sketch.gainsInDraw.allSatisfy { $0 == 0.25 }, "\(sketch.gainsInDraw)")
        }
    }

    @Test("保存された値は、区画を開かなくても戻り、setup() の時点で入っている")
    func savedValuesStillComeBack() throws {
        try withProductionFacets {
            let sketch = Tuned()
            try render(sketch, frames: 2)
            #expect(sketch.gainAtSetup == 0.25, "保存の値が戻っていない: \(String(describing: sketch.gainAtSetup))")
        }
    }

    /// **同じ置き方で、書き出しでない実行は区画を開く** — 上の検査が、区画に届く置き方で組まれている
    /// ことを示す (届かない置き方なら、開かないことを見ても何も言えない)。
    @Test("書き出しの頼みが無い実行は、これまでどおり 3 つの区画を開く")
    func otherRunsStillOpenTheFacets() throws {
        try withProductionFacets {
            let sketch = Tuned()
            let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
            try runtime.advance()
            runtime.closePlugins()

            #expect(contents("report.json", in: "input")?.contains("i1") == true)
            #expect(contents("report.json", in: "params") != Self.sentinel, "つまみの目録を書かなかった")
            #expect(
                contents("report.json", in: "params")?.contains("p1") == true,
                "つまみの要求に応えなかった")
        }
    }
}
