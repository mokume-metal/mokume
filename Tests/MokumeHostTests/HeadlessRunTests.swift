// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

/// 窓なしでスケッチを走らせる口 `HeadlessRun` (ADR-0048 決定 3・#3870)。GPU を要する。
///
/// 確かめの半分は、`HostOnlyFile.swift` が `import MokumeHost` だけで組めることである。ここは組めた結果、
/// 進める・読む・注入するが働き、**後始末を書かなくても差込口が閉じる**ことを見る。
@Suite(
    "MokumeHost の窓なしの実行",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .serialized)
@MainActor
struct HeadlessRunTests {
    @Test("進める・読む・注入する・PNG に書くが、import MokumeHost だけのファイルから働く")
    func advancesReadsAndInjects() throws {
        HostProbeSketch.declared = []
        let reading = try readAroundSpace(HostProbeSketch())
        #expect(reading.frameCount == 3)
        // 再現する時計: 30 fps で 3 枚目の頭は 2/30 秒
        #expect(abs(reading.time - 2.0 / 30) < 1e-4)
        #expect(abs(reading.deltaTime - 1.0 / 30) < 1e-4)
        // 押す前は赤 (作業空間の値)、押した後は青 (表示に変換した値)。作業空間は sRGB の原色を
        // そのまま (1, 0, 0) には持たないので、どちらの成分が勝つかで読む
        let red = reading.before[16, 16]
        #expect(red.red > red.blue + 0.5, "押す前の絵が赤でない: \(red)")
        let blue = reading.after[16, 16]
        #expect(Int(blue.blue) > Int(blue.red) + 128, "押した後の絵が青でない: \(blue)")
        #expect(reading.pngBytes > 0)
    }

    @Test("with を抜けたら、閉じる呼び出しを書かなくても差込口が 1 度だけ閉じる")
    func withClosesOnExit() throws {
        let outlet = CountingOutlet()
        HostProbeSketch.declared = [CountingPlugin(outlet: outlet)]
        defer { HostProbeSketch.declared = [] }
        _ = try readAroundSpace(HostProbeSketch())
        #expect(outlet.opened == 1)
        #expect(outlet.closed == 1)
    }

    @Test("with の外へ持ち出した参照が残っていても、抜けたときに閉じ、参照を手放しても 2 度は閉じない")
    func withClosesEvenIfEscaped() throws {
        let outlet = CountingOutlet()
        HostProbeSketch.declared = [CountingPlugin(outlet: outlet)]
        defer { HostProbeSketch.declared = [] }
        var escaped: AnyObject? = try escapeFromWith(HostProbeSketch())
        #expect(outlet.closed == 1)
        escaped = nil
        #expect(escaped == nil)
        #expect(outlet.closed == 1)
    }

    @Test("with の中で投げて抜けても、差込口が閉じる")
    func withClosesWhenBodyThrows() throws {
        let outlet = CountingOutlet()
        HostProbeSketch.declared = [CountingPlugin(outlet: outlet)]
        defer { HostProbeSketch.declared = [] }
        #expect(throws: DeliberateFailure.self) { try throwInside(HostProbeSketch()) }
        #expect(outlet.closed == 1)
    }

    @Test("持ち続けた実行は、参照を手放したら差込口が閉じる")
    func heldRunClosesWhenReleased() throws {
        let outlet = CountingOutlet()
        HostProbeSketch.declared = [CountingPlugin(outlet: outlet)]
        defer { HostProbeSketch.declared = [] }
        let viewer = try HostViewer(HostProbeSketch())
        try viewer.run?.advance()
        #expect(outlet.closed == 0)
        viewer.run = nil
        #expect(outlet.closed == 1)
    }
}
