// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI
@testable import MokumeCore

/// 試聴の間、**作品の窓の台とプレビューの台が別の世代を映す**ことを、見張りと台を繋いで見る (#3565 の完了条件 1・5・8)。
///
/// 子は本物のプロセス (`/bin/sh`) で、その番号を名乗る目録と面は検査が置く — 本番の子が書くのと同じ形
/// (区画 `viewport` の目録は 1 枚で、最後に書いた子のもので上書きされる)。台と見張りの繋ぎは
/// ``WatchCommand/connectAudition(_:window:preview:)`` を本番と同じに通す。窓は開かない (台の拍は検査が打つ)。
@Suite(
    "試聴中は、プレビューの台だけが試聴の子を映し、作品の窓の台は本番を映し続ける",
    .signalStateKept,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct WatchAuditionStageTests {
    /// 子の番号を名乗る目録と面を置く、子の替え玉。
    final class Writer {
        let surface: SharedFrameSurface
        let pid: Int32
        private let gpu: RenderDevice

        /// 面を作り、`pid` を名乗る目録を `facet` へ置いて、1 枚焼く。
        init(pid: Int32, facet: URL, gpu: RenderDevice, windowScale: Float? = nil) throws {
            self.pid = pid
            self.gpu = gpu
            surface = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            let manifest = SharedFrameSurface.Manifest(
                ids: surface.ids, width: 32, height: 32, windowScale: windowScale, pid: pid)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            try JSONEncoder().encode(manifest).write(to: url)
            // 見張りは更新時刻が変わったときだけ読み直す。同じ刻みに収まらないようにずらす
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Self.nextOffset())],
                ofItemAtPath: url.path)
            try draw(frame: 1)
        }

        /// 続けて置く目録の更新時刻を、必ず前より後ろにする。
        private static func nextOffset() -> TimeInterval {
            offset += 1
            return offset
        }
        nonisolated(unsafe) private static var offset: TimeInterval = 5

        func draw(frame: Int) throws {
            let source = try RenderTarget(gpu: gpu, width: 32, height: 32)
            try source.fill(with: .linear(red: 0, green: 0, blue: 0))
            let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
            try surface.write(
                source, using: presenter,
                numbers: FrameNumbers(
                    frameCount: frame, time: Double(frame) / 60, frameRate: 60, frameTimeMs: 16.7),
                pointerLock: false, cursorHidden: false, selection: nil)
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            try surface.publishPending()
        }
    }

    /// 見張りと 2 つの台を、本番と同じ繋ぎ方で組む。
    struct Rig {
        let harness: WatchAuditionTests.Harness
        let gpu: RenderDevice
        let window: SharedFrameWindow
        let preview: SharedFramePreview
        let facet: URL

        var session: WatchSession { harness.session }

        init() throws {
            harness = try WatchAuditionTests.Harness()
            gpu = try RenderDevice()
            facet = WatchCommand.viewportFacet(under: harness.session.facetBase)
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            window = try SharedFrameWindow(gpu: gpu, facet: facet, title: "audition-window")
            preview = try SharedFramePreview(gpu: gpu, facet: facet, title: "audition-preview")
            WatchCommand.connectAudition(harness.session, window: window, preview: preview)
        }

        /// 2 つの台に 1 拍ずつ打たせ、乗り換えの合図を見張りへ渡す。
        func tick() async {
            var promoted: [Int32?] = []
            window.onGenerationPromoted = { promoted.append($0) }
            preview.onGenerationPromoted = { promoted.append($0) }
            window.stage.displayLinkFired()
            preview.stage.displayLinkFired()
            for pid in promoted { await session.generationPromoted(pid: pid) }
        }

        /// 本番の子の目録を、本番の子のまま書き直す。
        func writer(for process: Process, windowScale: Float? = nil) throws -> Writer {
            try Writer(
                pid: process.processIdentifier, facet: facet, gpu: gpu, windowScale: windowScale)
        }
    }

    @Test("試聴に入って保存すると、プレビューの台は試聴の子の pid になり、作品の窓の台は本番の pid のまま")
    func savingWhileAuditioningMovesOnlyThePreview() async throws {
        let rig = try Rig()
        let production = try #require(await rig.harness.save())
        let productionWriter = try rig.writer(for: production, windowScale: 0.5)
        await rig.tick()
        #expect(rig.window.displayedPID == production.processIdentifier)
        #expect(rig.preview.displayedPID == production.processIdentifier)

        _ = try await rig.harness.ask("audition")
        // 入っただけでは、どちらの台も動かない
        await rig.tick()
        #expect(rig.window.displayedPID == production.processIdentifier)
        #expect(rig.preview.displayedPID == production.processIdentifier)

        // 背景色を変えて保存した: 試聴の子が目録を置き直し、1 枚焼いた
        let first = try #require(await rig.harness.save())
        let firstWriter = try rig.writer(for: first, windowScale: 1)
        await rig.tick()
        #expect(
            rig.preview.displayedPID == first.processIdentifier,
            "プレビューが試聴の子へ乗り換えない: \(String(describing: rig.preview.displayedPID))")
        #expect(
            rig.window.displayedPID == production.processIdentifier,
            "作品の窓が保存の前から変わった: \(String(describing: rig.window.displayedPID))")
        #expect(production.isRunning, "本番の子が止まった")

        // もう 1 度保存: 試聴の子だけが入れ替わる
        let second = try #require(await rig.harness.save())
        let secondWriter = try rig.writer(for: second)
        await rig.tick()
        #expect(rig.preview.displayedPID == second.processIdentifier)
        #expect(rig.window.displayedPID == production.processIdentifier)
        #expect(!first.isRunning && production.isRunning)

        // 本番が目録を書き直した (大きさなど)。作品の窓はそれを採り、プレビューには採らない
        let rewritten = try rig.writer(for: production, windowScale: 2)
        await rig.tick()
        #expect(rig.window.displayedPID == production.processIdentifier)
        #expect(rig.preview.displayedPID == second.processIdentifier, "試聴中に本番の目録をプレビューが採った")

        // 出る: 試聴の子が止まり、プレビューは本番の pid へ戻る
        let report = try await rig.harness.ask("leave")
        #expect(report["accepted"] as? Bool == true)
        await rig.tick()
        #expect(!second.isRunning)
        #expect(
            rig.preview.displayedPID == production.processIdentifier,
            "プレビューが本番へ戻らない: \(String(describing: rig.preview.displayedPID))")
        #expect(rig.window.displayedPID == production.processIdentifier)

        // 出た後の保存は、これまでどおり両方の台を入れ替える
        let third = try #require(await rig.harness.save())
        let thirdWriter = try rig.writer(for: third)
        await rig.tick()
        #expect(rig.window.displayedPID == third.processIdentifier)
        #expect(rig.preview.displayedPID == third.processIdentifier)
        _ = (productionWriter, firstWriter, secondWriter, rewritten, thirdWriter)
    }

    @Test("試聴に入らなければ、保存で両方の台が同時に乗り換わる (これまでどおり)")
    func withoutAuditionBothStagesSwap() async throws {
        let rig = try Rig()
        let first = try #require(await rig.harness.save())
        let firstWriter = try rig.writer(for: first)
        await rig.tick()
        let second = try #require(await rig.harness.save())
        let secondWriter = try rig.writer(for: second)
        await rig.tick()
        #expect(rig.window.displayedPID == second.processIdentifier)
        #expect(rig.preview.displayedPID == second.processIdentifier)
        _ = (firstWriter, secondWriter)
    }

    @Test("試聴の子が落ちても、作品の窓の台は本番を映し続け、プレビューの台は試聴の最後の絵を残す")
    func theCrashedAuditionLeavesTheWindowsAlone() async throws {
        let rig = try Rig()
        let production = try #require(await rig.harness.save())
        let productionWriter = try rig.writer(for: production)
        await rig.tick()
        _ = try await rig.harness.ask("audition")
        let audition = try #require(await rig.harness.save())
        let auditionWriter = try rig.writer(for: audition)
        await rig.tick()
        rig.session.generationShown(pid: audition.processIdentifier)
        #expect(rig.preview.displayedPID == audition.processIdentifier)

        rig.harness.tell(audition, "crash")
        await rig.harness.beat()
        await rig.tick()
        #expect(production.isRunning)
        #expect(rig.window.displayedPID == production.processIdentifier)
        #expect(rig.preview.displayedPID == audition.processIdentifier, "止まった絵を捨てた")
        _ = (productionWriter, auditionWriter)
    }
}
