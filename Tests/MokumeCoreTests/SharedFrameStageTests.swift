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

    /// 2 枚が同じ名前で位置を覚えると、互いを上書きして重なって開く。
    @Test("作品の窓とプレビューは、別の名前で位置を覚える")
    func placementNamesDiffer() {
        #expect(WindowPlacement.autosaveName != WindowPlacement.previewAutosaveName)
    }
}
