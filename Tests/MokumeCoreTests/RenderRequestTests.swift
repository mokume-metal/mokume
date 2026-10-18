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

    /// **`.mov` の時刻は 1/90 000 秒で数える** ([#2307])。それより速い fps では隣の枚が同じ時刻に
    /// なり、書き出せない組になる。連番は時刻を書かないので、上限は掛からない。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    @Test("刻みを越える fps の .mov では組まず、刻みちょうどと連番は組む")
    func aMovieFasterThanItsTimescaleIsRefused() {
        let limit = RenderRequest.movieFrameRateLimit
        #expect(limit == 90_000)
        #expect(RenderRequest(frameRate: limit + 1, frameCount: 10, destination: "/tmp/a.mov") == nil)
        #expect(RenderRequest(frameRate: limit, frameCount: 10, destination: "/tmp/a.mov") != nil)
        #expect(
            RenderRequest(frameRate: limit + 1, frameCount: 10, destination: "/tmp/f-###.png") != nil)
        #expect(RenderRequest(environmentValue: "\(limit + 1):10:/tmp/a.mov") == nil)
    }

    @Test(
        "読めない値からは組まない",
        arguments: ["", "30", "30:120", "x:120:/tmp/a.mov", "30:y:/tmp/a.mov", "30:120:/tmp/a.png"])
    func malformedValuesAreRefused(value: String) {
        #expect(RenderRequest(environmentValue: value) == nil)
    }

    /// **合図が無ければ、いつもの窓の経路。** 合図が在って読めなければ、窓へ倒さず断る ([#2481])。
    /// 窓を開いて 0 で終わると、`mokume render` は書けたと読んで、何も書かれていないのに名乗っていた。
    ///
    /// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
    @Test("起動の瞬間の読みは、合図が無ければ頼みを持たず、読めない合図は断る")
    func theStartupReadRefusesAnUnreadableSignal() throws {
        let key = StartupReads.render.key
        #expect(try RenderRequest.startup(environment: [:]) == nil)
        #expect(
            try RenderRequest.startup(environment: [key: "24:48:/tmp/a.mov"])
                == RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/a.mov"))
        // 窓へ倒す (`nil`) のでなく、読めなかった値を名乗って断る
        for value in ["not a request", "", "30:120", "0:10:/tmp/a.mov", "24:48:/tmp/a.png"] {
            #expect(
                throws: RenderFailure.unreadableRenderRequest(value: value),
                "読めない値 \(value.debugDescription) を窓へ倒している"
            ) {
                try RenderRequest.startup(environment: [key: value])
            }
        }
    }

    /// 書き出せない組 (fps が `.mov` の上限を越える) も、形は読めても断る。
    @Test("書き出せない組も、窓へ倒さず断る")
    func anUnwritableRequestIsRefusedToo() {
        let key = StartupReads.render.key
        let value = "\(RenderRequest.movieFrameRateLimit + 1):10:/tmp/a.mov"
        #expect(throws: RenderFailure.unreadableRenderRequest(value: value)) {
            try RenderRequest.startup(environment: [key: value])
        }
    }

    /// 起動の行が出す文面に、読めなかった値と、直し方が載る。
    @Test("断った起動の文面は、読めなかった値と環境変数の名前を名乗る")
    func theRefusalNamesTheValueAndTheVariable() {
        let value = "not a request"
        let text = startupFailureText(.unreadableRenderRequest(value: value))
        #expect(text.contains(value))
        #expect(text.contains(StartupReads.render.key))
        #expect(text.contains("<fps>:<frames>:<where to write>"))
        #expect(text.hasSuffix("\n"))
    }

    /// 道具が決めて子へ渡すもの。一覧に載っていれば `doctor` と窓口の案内にも出る。
    @Test("合図は道具が決める環境変数として一覧に載る")
    func theSignalIsListedAsTheTools() {
        #expect(StartupReads.render.origin == .environment)
        #expect(StartupReads.render.decidedBy == .tool)
        #expect(StartupReads.all.contains { $0.key == StartupReads.render.key })
    }
}
