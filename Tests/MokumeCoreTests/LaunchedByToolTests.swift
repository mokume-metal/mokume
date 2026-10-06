// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 画面の出口と道具の管を誰が持つかは、**起こし方**で決まる ([#2028])。
///
/// 見張り (`watch`) が起こした子だけが、窓を持たずに共有面へ差し出し、標準入力の管を読む。
/// それ以外の実行は、同じ場所に区画 `.mokume/viewport` が在っても自分の窓を開き、標準入力
/// にも見張りの目録 (`surface.json`) にも触らない ([ADR-0032] 決定 1)。かつては区画の在る
/// 無しで起こし方を代用しており、居合わせた実行が見張りの窓と管を奪っていた — 標準入力に
/// `O_NONBLOCK` を残す (#2024)・閉じた標準入力で書き出しが 0 枚で止まる (#2025)・見張りの
/// 目録を上書きして窓を開かない (#2026)。
///
/// ## 区画は本番と同じ場所に置く
///
/// **既定引数が見る場所そのもの** (`WorkDirectory.facet(StartupReads.viewport.key)`) に置く。
/// 以前の検査は区画を `resolveOutlet(at:)` に直に渡して出口だけを見ていたので、既定引数で
/// 本番の場所を見ていた標準入力の管が、検査では一度も開かなかった — #2025 の形はそこで
/// 検査の外にあった。標準入力も同じ理由で、差し替えるのはプロセスの `STDIN_FILENO` そのもの
/// である (走らせている端末へは触らせない)。
///
/// **1 本ずつ走らせる** — 区画も標準入力もプロセスで 1 つなので、並べると互いの置いたものを
/// 見る。
///
/// [#2028]: https://github.com/mokume-metal/mokume/issues/2028
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@Suite(
    "起こし方で、画面の出口と道具の管が決まる",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct LaunchedByToolTests {
    /// 何も描かないスケッチ。
    private final class Blank: Sketch {
        var settings: SketchSettings { SketchSettings(width: 32, height: 16, frameRate: 60) }
        func draw() { background(0) }
    }

    /// 見張りが書いた目録を装う。起票時の再現 (#2026) と同じ中身。
    private static let watchedManifest =
        #"{"height":120,"ids":[1,2,3,4],"schemaVersion":1,"width":160}"#

    /// 標準入力に `O_NONBLOCK` が立っているか。
    private static var standardInputIsNonBlocking: Bool {
        fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK != 0
    }

    /// 本番と同じ場所に区画 `viewport` を置いて本体を走らせ、終わったら元へ戻す。
    ///
    /// **手元に元から在ったものは退かせて戻す** — 開発者が残した区画を消さず、それに
    /// 左右されもしない。
    private func withProductionFacet<T>(
        manifest: String? = nil, _ body: (URL) throws -> T
    ) throws -> T {
        let facet = WorkDirectory.facet(StartupReads.viewport.key)
        let manager = FileManager.default
        let aside = facet.deletingLastPathComponent()
            .appendingPathComponent("viewport-aside-\(UUID().uuidString)", isDirectory: true)
        let root = facet.deletingLastPathComponent()
        let hadRoot = WorkDirectory.directoryExists(at: root)
        let hadOne = WorkDirectory.directoryExists(at: facet)
        if hadOne { try manager.moveItem(at: facet, to: aside) }
        defer {
            try? manager.removeItem(at: facet)
            if hadOne { try? manager.moveItem(at: aside, to: facet) }
            // 置いた `.mokume` は畳む (作業ツリーに空の区画の親を残さない)
            if !hadRoot, (try? manager.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
                try? manager.removeItem(at: root)
            }
        }
        try manager.createDirectory(at: facet, withIntermediateDirectories: true)
        if let manifest {
            try Data(manifest.utf8).write(
                to: facet.appendingPathComponent(SharedFrameSurface.manifestName))
        }
        return try body(facet)
    }

    /// プロセスの標準入力を `descriptor` へ差し替えて本体を走らせ、終わったら元へ戻す。
    private func withStandardInput<T>(_ descriptor: Int32, _ body: () throws -> T) throws -> T {
        let saved = dup(STDIN_FILENO)
        try #require(saved >= 0, "標準入力を控えられない")
        try #require(dup2(descriptor, STDIN_FILENO) >= 0, "標準入力を差し替えられない")
        defer {
            dup2(saved, STDIN_FILENO)
            close(saved)
        }
        return try body()
    }

    /// 窓の経路で組む。**終わりの行き先は赤を記録する口へ差し替える** — 既定の
    /// `terminate(nil)` は検査のプロセスを終わらせる (`SketchApplicationTests` と同じ理由)。
    private func makeApplication() throws -> SketchApplication {
        let application = try SketchApplication(sketch: Blank(), gpu: RenderDevice())
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        return application
    }

    /// 書き口を閉じた管 — 読めば「相手が畳んだ」(0 バイト) が返る。CI・エージェント・cron の
    /// 閉じた標準入力と同じ読まれ方をし、フラグも読み取れる。
    private func closedPipe() throws -> Pipe {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        return pipe
    }

    // MARK: - 窓を持たない SketchRuntime (#2024)

    @Test("区画が在っても、窓を持たない SketchRuntime は標準入力のフラグを変えない")
    func aWindowlessRuntimeLeavesStandardInputAlone() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        try withProductionFacet { _ in
            try withStandardInput(pipe.fileHandleForReading.fileDescriptor) {
                let before = Self.standardInputIsNonBlocking
                let runtime = try SketchRuntime(sketch: Blank(), gpu: RenderDevice())
                try runtime.advance()
                runtime.closePlugins()
                #expect(Self.standardInputIsNonBlocking == before, "標準入力に O_NONBLOCK を立てた")
                #expect(!runtime.takeDriverDeparture())
            }
        }
    }

    // MARK: - 書き出す経路 (#2025)

    @Test("区画が在り標準入力が閉じていても、書き出す経路は管を開かずに頼んだ枚数を書いて終わる")
    func renderingIgnoresTheFacetAndAClosedStandardInput() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-launched-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let request = try #require(
            RenderRequest(
                frameRate: 30, frameCount: 3,
                destination: output.appendingPathComponent("f-####.png").path))
        let pipe = try closedPipe()

        try withProductionFacet(manifest: Self.watchedManifest) { facet in
            try withStandardInput(pipe.fileHandleForReading.fileDescriptor) {
                let before = Self.standardInputIsNonBlocking
                let application = try SketchApplication(
                    sketch: Blank(), gpu: RenderDevice(), render: request)
                var finished = 0
                var stopped = 0
                var reply: NSApplication.TerminateReply?
                var replied = false
                var exitStatus: Int32?
                application.onRenderFinished = { [weak application] in
                    finished += 1
                    reply = application?.shouldTerminate()
                }
                application.onStopSignal = { [weak application] in
                    stopped += 1
                    reply = application?.shouldTerminate()
                }
                application.replyToTermination = { replied = true }
                application.exitProcess = { exitStatus = $0 }

                // 本番と同じ既定引数で出口を決める (区画も合図も既定の場所から読む)
                application.resolveOutlet()
                application.didFinishLaunching()
                for _ in 0..<6 { application.displayLinkFired() }
                if reply == .terminateLater {
                    let deadline = DispatchTime.now() + 60
                    while !replied, DispatchTime.now() < deadline {
                        application.pollTermination()
                        if !replied { Thread.sleep(forTimeInterval: 0.005) }
                    }
                    try #require(replied, "60 秒待っても後始末が済まない")
                }
                application.willTerminate()

                #expect(stopped == 0, "閉じた標準入力を、道具が去ったと読んで止めた")
                #expect(finished == 1)
                #expect(exitStatus == nil, "頼んだ枚数を書いたのに 0 以外で終わった")
                #expect(!application.driverDeparted())
                #expect(Self.standardInputIsNonBlocking == before, "標準入力に O_NONBLOCK を立てた")
                let written = try FileManager.default.contentsOfDirectory(atPath: output.path)
                    .filter { $0.hasSuffix(".png") }
                #expect(written.count == 3, "3 枚を頼んで \(written.count) 枚")
                #expect(
                    try String(
                        contentsOf: facet.appendingPathComponent(SharedFrameSurface.manifestName),
                        encoding: .utf8) == Self.watchedManifest,
                    "見張りの目録を書き換えた")
            }
        }
    }

    // MARK: - 窓の経路 (#2026)

    @Test("区画が在っても合図が無ければ、自分の窓を開き、目録に触らず、そのことを 1 度名乗る")
    func withoutTheSignalTheSketchOpensItsOwnWindow() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        try withProductionFacet(manifest: Self.watchedManifest) { facet in
            try withStandardInput(pipe.fileHandleForReading.fileDescriptor) {
                let before = Self.standardInputIsNonBlocking
                let application = try makeApplication()
                defer { application.willTerminate() }
                var said: [String] = []
                application.announce = { said.append($0) }

                // 本番と同じ既定引数 — 検査のプロセスには合図が渡っていない
                #expect(SharedFrameSurface.launchOwner == nil, "検査のプロセスに合図が立っている")
                application.resolveOutlet()

                #expect(application.endsAfterLastWindowClosed, "窓の経路になっていない")
                #expect(application.activationPolicy == .regular, "Dock に並ばない (窓を開かない) 経路になった")
                #expect(
                    try String(
                        contentsOf: facet.appendingPathComponent(SharedFrameSurface.manifestName),
                        encoding: .utf8) == Self.watchedManifest,
                    "見張りの目録を書き換えた")
                #expect(said.count == 1, "区画が在るのに窓を開くことを名乗っていない (\(said))")
                #expect(said.first?.contains(facet.path) == true, "名乗りが区画の在処を言わない")
                // 古い見張りは合図を渡さないので、見張りから起こした人を版のずれへ導く
                #expect(said.first?.contains("mokume watch") == true, "版のずれを疑わせる手掛かりが無い")
                #expect(Self.standardInputIsNonBlocking == before, "標準入力に O_NONBLOCK を立てた")
                #expect(!application.driverDeparted())
            }
        }
    }

    /// **区画が無ければ名乗らない。** 直に走らせたいつもの実行の出力を 1 行も増やさない。
    @Test("区画が無ければ、窓を開くことを名乗らない")
    func withoutTheFacetNothingIsSaid() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        let application = try makeApplication()
        defer { application.willTerminate() }
        var said: [String] = []
        application.announce = { said.append($0) }
        application.resolveOutlet(at: missing, owner: nil)
        #expect(said.isEmpty)
        #expect(application.endsAfterLastWindowClosed)
    }

    // MARK: - 見張りの子 (合図あり・#1427 はそのまま)

    @Test("合図のある子は、窓を開かずに共有面へ差し出し、目録を置き、管を読み、管が畳まれたら気付く")
    func withTheSignalTheChildHandsFramesToTheTool() throws {
        try withProductionFacet(manifest: Self.watchedManifest) { facet in
            let pipe = Pipe()
            let application = try makeApplication()
            defer { application.willTerminate() }
            var said: [String] = []
            application.announce = { said.append($0) }
            application.toolInput = pipe.fileHandleForReading.fileDescriptor

            application.resolveOutlet(owner: "mokume watch")

            #expect(!application.endsAfterLastWindowClosed, "窓の経路のまま")
            #expect(application.activationPolicy == .accessory)
            #expect(said.isEmpty, "合図があるのに、窓を開くと名乗った")
            let placed = try String(
                contentsOf: facet.appendingPathComponent(SharedFrameSurface.manifestName),
                encoding: .utf8)
            #expect(placed != Self.watchedManifest, "自分の面の番号を目録に置いていない")
            // 管を読み始めている — 読み口は塞がない形になる
            let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
            #expect(flags & O_NONBLOCK != 0, "道具の管を読んでいない")
            #expect(!application.driverDeparted())
            try pipe.fileHandleForWriting.close()
            #expect(application.driverDeparted(), "道具が管を畳んだのに気付かない")
        }
    }

    /// **全画面の頼みに応えられないことを、黙らない** ([#2020])。作品の窓は道具が持つので
    /// ([ADR-0032] 決定 1)、子からは全画面にできない。描く大きさはディスプレイから決まっている。
    ///
    /// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
    @Test("全画面を頼む見張りの子は、窓を道具が持つことを 1 度名乗る")
    func aFullScreenChildSaysTheToolHoldsTheWindow() throws {
        try withProductionFacet(manifest: Self.watchedManifest) { _ in
            let pipe = Pipe()
            let application = try SketchApplication(
                sketch: FullScreenBlank(display: 2), gpu: RenderDevice(), render: nil,
                displays: { SmallDisplays.both })
            application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
            defer { application.willTerminate() }
            var said: [String] = []
            application.announce = { said.append($0) }
            application.toolInput = pipe.fileHandleForReading.fileDescriptor

            application.resolveOutlet(owner: "mokume watch")

            #expect(!application.endsAfterLastWindowClosed, "共有面の経路になっていない")
            #expect(said.count == 1, "\(said)")
            #expect(said.first?.contains("full screen on display 2 (Projector)") == true)
            #expect(said.first?.contains("mokume watch holds the window") == true)
        }
    }
    /// **共有面を用意できずに窓へ倒れても、見張りの子は管を読む。** 管を引いたのは見張りで、
    /// 見張りが去ったことに気付く口はこの管しか無い ([#1427](https://github.com/mokume-metal/mokume/issues/1427))。
    /// 区画に目録を書けない形 (書き込めない区画) で倒す。
    @Test("合図と区画が揃っていれば、共有面を用意できずに窓へ倒れても、管を読んで道具の去ったことに気付く")
    func aChildThatFallsBackToAWindowStillWatchesTheTool() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: facet.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)
            try? FileManager.default.removeItem(at: facet)
        }
        let pipe = Pipe()
        let application = try makeApplication()
        defer { application.willTerminate() }
        application.toolInput = pipe.fileHandleForReading.fileDescriptor

        application.resolveOutlet(at: facet, owner: "mokume watch")

        #expect(application.endsAfterLastWindowClosed, "目録を書けないのに共有面の経路になった")
        let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
        #expect(flags & O_NONBLOCK != 0, "窓へ倒れた見張りの子が、道具の管を読んでいない")
        #expect(!application.driverDeparted())
        try pipe.fileHandleForWriting.close()
        #expect(application.driverDeparted(), "窓へ倒れた見張りの子が、道具の去ったことに気付かない")
    }

    // MARK: - 合図を子孫へ継がせない

    /// **合図はこのプロセスを起こした道具のもので、このプロセスが起こす子のものではない。**
    /// 見張りの子のスケッチが `Process` で別の実行ファイルを直に起こすと、継いだ孫まで見張りの
    /// 窓と管を持っているかのように振る舞う (#2028)。読んだら環境から消す。
    @Test("合図は読んだときに環境から消え、起こした子へは継がれない")
    func theSignalIsNotInheritedByChildren() throws {
        let key = StartupReads.viewportOwner.key
        // 控えを先に確定させる — 下で立てる合図を、この検査のプロセスの控えにしない
        _ = SharedFrameSurface.launchOwner
        setenv(key, "mokume watch", 1)
        defer { unsetenv(key) }

        #expect(SharedFrameSurface.takeOwner() == "mokume watch")
        #expect(getenv(key) == nil, "読んだ合図が環境に残っている")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf '%s' \"${\(key)-unset}\""]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        child.waitUntilExit()
        let seen = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(seen == "unset", "起こした子が合図を継いだ (\(seen ?? "?"))")

        // 載っていなければ消しに行かない (他の変数に触らない)
        var unsetCalls = 0
        #expect(SharedFrameSurface.takeOwner(from: [:], unset: { _ in unsetCalls += 1 }) == nil)
        #expect(unsetCalls == 0)
    }
}
