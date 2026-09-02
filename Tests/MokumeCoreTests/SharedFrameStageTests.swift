// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 道具が出す 2 種類の窓。
///
/// **作品の窓に道具の都合が出ないことを、構造で見る。** 「載せないように気をつける」では
/// 検められないので、載せる場所そのものが無いことを見る
/// ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 1)。
@Suite(
    "道具が出す窓",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SharedFrameStageTests {
    /// 区画を 1 つ作って渡す。後片付けまで面倒を見る。
    private func withFacet<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func look(_ name: String) -> SharedFrameStage.Look {
        SharedFrameStage.Look(
            title: name, autosaveName: "mokume.test.\(name)",
            defaultSize: NSSize(width: 320, height: 180))
    }

    @Test("重ねる面を渡さなければ、絵の面には何も足されない")
    func artworkWindowCarriesNothing() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(gpu: RenderDevice(), facet: facet, look: look("bare"))
            stage.open()
            defer { stage.close() }
            let content = try #require(stage.window?.contentView)
            #expect(content.subviews.isEmpty)
        }
    }

    @Test("重ねる面を渡すと、絵の面の上に足される")
    func previewCarriesTheNotice() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("notice"))
            let notice = NoticeOverlay()
            stage.open(overlay: notice)
            defer { stage.close() }
            let content = try #require(stage.window?.contentView)
            #expect(content.subviews.contains { $0 === notice })
        }
    }

    /// **プレビューは作品の窓の子ではない。** 作品が窓を持たない日 (外へ流すだけの作品) に
    /// プレビューだけを出せる形かどうかは、片方だけを開いて確かめられる。
    @Test("プレビューは、作品の窓を作らなくても開いて畳める")
    func previewStandsAlone() throws {
        try withFacet { facet in
            let preview = try SharedFramePreview(
                gpu: RenderDevice(), facet: facet, title: "単体")
            preview.open()
            preview.report("作っている…", spinning: true)
            preview.close()
        }
    }

    /// **覚えている枠が無いときに、寸分違わず重ならない。**
    ///
    /// どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が完全に重なり、窓が 1 つしか
    /// 無いように見える (実測)。**その場限りの覚え名で開く** — 覚えた枠が残っている機械では
    /// 中央へ出ないので、それでは初めての 1 回を見たことにならない。
    @Test("初めて開くとき、2 枚は重ならない")
    func freshWindowsDoNotOverlap() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: look(fresh()))
            var previewLook = look(fresh())
            previewLook.nudge = SharedFramePreview.nudge
            let preview = try SharedFrameStage(gpu: gpu, facet: facet, look: previewLook)
            artwork.open()
            preview.open()
            defer {
                artwork.close()
                preview.close()
            }
            #expect(try #require(artwork.window?.frame) != #require(preview.window?.frame))
        }
    }

    /// 覚えた枠を引き継がないための、その場限りの名前。
    private func fresh() -> String { "fresh-\(UUID().uuidString)" }

    /// **拾った 1 件は、合流点と運び先の両方へ行く。**
    ///
    /// 道具の窓では絵を描いているのが別のプロセスなので、運ばないと何も起きない
    /// ([ADR-0032] 決定 4)。運ぶだけにすると、こんどは窓の側の合流点が空になる。
    @Test("窓が拾った出来事は、合流点へも運び先へも行く")
    func deliveredEventsGoBothWays() throws {
        let gpu = try RenderDevice()
        let state = InputState()
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10), device: gpu.device, input: state,
            canvasSize: (10, 10))
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        surface.deliver(.mouseMoved(x: 3, y: 4))
        state.beginFrame()
        #expect(state.x == 3)
        #expect(lines == [InputEvent.mouseMoved(x: 3, y: 4).wireLine])
    }

    /// **つまみはプレビューにだけ出る** ([ADR-0032] 決定 5)。見張りから本番を回している
    /// 間、つまみが本番の画面に出てはならない。
    @Test("宣言があればプレビューにつまみが出て、作品の窓には出ない")
    func knobsGoToThePreviewOnly() throws {
        try withFacet { facet in
            let params = facet.appendingPathComponent("params", isDirectory: true)
            try FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)
            let report = ParamReport(
                revision: 1, id: nil,
                params: [ParamDeclaration(name: "size", value: .float(12))],
                rejected: [], clamped: [], discarded: [])
            try AtomicFile.write(
                try JSONEncoder().encode(report),
                to: params.appendingPathComponent(ParamSurface.reportFileName))

            let gpu = try RenderDevice()
            let preview = try SharedFramePreview(
                gpu: gpu, facet: facet, params: params, title: "つまみ")
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: look("bare-knobs"))
            preview.open()
            artwork.open()
            defer {
                preview.close()
                artwork.close()
            }
            #expect(preview.hasKnobs)
            #expect(try #require(artwork.window?.contentView).subviews.isEmpty)
        }
    }

    /// いまの `KnobOverlay.makeIfNeeded` の振る舞いを保つ (ADR-0030 決定 8)。
    @Test("宣言が 1 つも無ければ、つまみは足さない")
    func addsNothingWithoutDeclarations() throws {
        try withFacet { facet in
            let params = facet.appendingPathComponent("params", isDirectory: true)
            try FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)
            let preview = try SharedFramePreview(
                gpu: try RenderDevice(), facet: facet, params: params, title: "空")
            preview.open()
            defer { preview.close() }
            #expect(!preview.hasKnobs)
        }
    }

    /// 2 枚が同じ名前で位置を覚えると、互いを上書きして重なって開く。
    @Test("作品の窓とプレビューは、別の名前で位置を覚える")
    func placementNamesDiffer() {
        #expect(WindowPlacement.autosaveName != WindowPlacement.previewAutosaveName)
    }
}
