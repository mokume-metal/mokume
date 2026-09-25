// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 書き出しの頼み (`mokume render`・[#1282])。GPU は要らない。
///
/// **道具と子が同じ型で読み書きする**ので、ここが見るのは「組めない頼みを作らない」ことと
/// 「渡した値がそのまま戻る」ことである。道具の側からの往復は `RenderCommandTests` が見る。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
@Suite("書き出しの頼み")
struct RenderRequestTests {
    @Test("環境の値へ載せて読み戻すと、同じ頼みに戻る")
    func theEnvironmentValueRoundTrips() throws {
        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 120, destination: "/tmp/out/motion.mov"))
        #expect(request.environmentValue == "30:120:/tmp/out/motion.mov")
        #expect(RenderRequest(environmentValue: request.environmentValue) == request)
    }

    /// **行き先は最後に置く。** `:` を含むパスも切らずに運ぶ。
    @Test("行き先に : を含んでも、切らずに運ぶ")
    func aColonInTheDestinationSurvives() throws {
        let request = try #require(
            RenderRequest(frameRate: 60, frameCount: 1, destination: "/tmp/a:b/frame-####.png"))
        let back = try #require(RenderRequest(environmentValue: request.environmentValue))
        #expect(back.destination == "/tmp/a:b/frame-####.png")
    }

    /// **行き先の規則は撮る係のもの。** `.mov` か、番号の入る場所 (`#`) を持つ連番だけ。
    @Test(
        "撮る係が受けない行き先では組まない",
        arguments: ["/tmp/still.png", "/tmp/motion", "/tmp/motion.mp4", ""])
    func unrecordableDestinationsAreRefused(destination: String) {
        #expect(RenderRequest(frameRate: 30, frameCount: 10, destination: destination) == nil)
    }

    @Test("撮る係が受ける綴りなら組む (大文字の .MOV も)", arguments: ["/tmp/a.mov", "/tmp/A.MOV", "/tmp/f-###.png"])
    func recordableDestinationsAreTaken(destination: String) {
        #expect(RenderRequest(frameRate: 30, frameCount: 10, destination: destination) != nil)
    }

    /// 境目: 0 枚・0 fps は書き出しにならない。1 は通る。
    @Test("速さも枚数も 1 以上でなければ組まない")
    func zeroIsRefusedAndOneIsTaken() {
        #expect(RenderRequest(frameRate: 0, frameCount: 10, destination: "/tmp/a.mov") == nil)
        #expect(RenderRequest(frameRate: 30, frameCount: 0, destination: "/tmp/a.mov") == nil)
        #expect(RenderRequest(frameRate: -1, frameCount: 10, destination: "/tmp/a.mov") == nil)
        #expect(RenderRequest(frameRate: 1, frameCount: 1, destination: "/tmp/a.mov") != nil)
    }

    @Test(
        "読めない値からは組まない",
        arguments: ["", "30", "30:120", "x:120:/tmp/a.mov", "30:y:/tmp/a.mov", "30:120:/tmp/a.png"])
    func malformedValuesAreRefused(value: String) {
        #expect(RenderRequest(environmentValue: value) == nil)
    }

    /// **合図が無ければ、いつもの窓の経路。** 読めない合図も窓の経路へ倒す (名乗ってから)。
    @Test("起動の瞬間の読みは、合図が無いか読めなければ頼みを持たない")
    func theStartupReadFallsBackToTheWindow() {
        let key = StartupReads.render.key
        #expect(RenderRequest.startup(environment: [:]) == nil)
        #expect(RenderRequest.startup(environment: [key: "not a request"]) == nil)
        #expect(
            RenderRequest.startup(environment: [key: "24:48:/tmp/a.mov"])
                == RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/a.mov"))
    }

    /// 道具が決めて子へ渡すもの。一覧に載っていれば `doctor` と窓口の案内にも出る。
    @Test("合図は道具が決める環境変数として一覧に載る")
    func theSignalIsListedAsTheTools() {
        #expect(StartupReads.render.origin == .environment)
        #expect(StartupReads.render.decidedBy == .tool)
        #expect(StartupReads.all.contains { $0.key == StartupReads.render.key })
    }
}
