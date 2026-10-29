// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// スケッチが起こした `Task` から、音の待つ読み込みの口 (`requestSound`) を呼ぶ ([#3398])。
///
/// `selectInput` の結果は `Task` に届く。そこでは `runningSketch` が外れているので、同期の `loadSound` は
/// `notRunning` を投げ、`draw()` へ持ち越して読むと「`draw()` の中の同期の読み込み」の警告が出る。
/// `requestSound` は、`Task` が持ち越した窓口 (``AttachRequests``) へ足すことを頼み、**実行がフレームの頭で
/// 足し終えてから**返る。待つ検査は、フレームを回しながら待つ — 頭で当てる者が実行だからである。
///
/// **呼んだ時点で差し込みが外れていたことを、検査が自分で確かめる** (`RequestFromTaskTests` と同じ)。
///
/// [#3398]: https://github.com/mokume-metal/mokume/issues/3398
@Suite(
    "Task から待たずに音を読む",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RequestSoundTests {
    /// `Task` を起こして、音を `requestSound` で読むスケッチ。
    final class Requesting: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        var path = ""
        /// 機材に出さずに鳴らす流れ。`nil` なら機材。
        var flow: SoundFlow?
        /// `setup()` で `noLoop()` を呼ぶか (止めている間も待ちが終わるか)。
        var stopsLooping = false
        /// `Task` を `setup()` ではなく最初の `draw()` で起こすか。
        var startsInDraw = false
        /// 同じ `Task` の中で、同期の `loadSound` も呼ぶか。
        var alsoLoadsSynchronously = false
        var loading: Task<Void, Never>?
        /// `Task` が終わったか。検査はフレームを回しながらこれを待つ。
        var finished = false
        var song: SoundFile?
        var failure: AudioFailure?
        var synchronousFailure: AudioFailure?
        /// 口を呼んだ時点で、差し込み (``runningSketch``) が外れていたか。
        var detachedWhenCalled: [Bool] = []

        init() {}

        func setup() {
            if stopsLooping { noLoop() }
            if !startsInDraw { startLoading() }
        }

        func draw() {
            if startsInDraw, loading == nil { startLoading() }
            background(0)
        }

        private func startLoading() {
            loading = Task {
                defer { finished = true }
                if alsoLoadsSynchronously {
                    do { _ = try loadSound(path) } catch { synchronousFailure = error as? AudioFailure }
                }
                detachedWhenCalled.append(runningSketch == nil)
                do {
                    song = try await requestSound(path, flow: flow)
                } catch {
                    failure = error as? AudioFailure
                }
            }
        }
    }

    private func makeRuntime(_ sketch: Requesting) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
    }

    /// フレームを回しながら、`done` になるのを待つ。**期限を越えたら失敗にして返る** — 待つ側が期限を持つ。
    private func drive(_ runtime: SketchRuntime, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !done() {
            guard ContinuousClock.now < deadline else {
                Issue.record("30 秒たっても Task が終わらない")
                return
            }
            try runtime.advance()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func flow() throws -> SoundFlow {
        try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
    }

    @Test(
        "setup() / draw() で起こした Task から requestSound を呼ぶと、足された SoundFile が返り、鳴らせる",
        arguments: [false, true])
    func aSoundArrivesAtARunningTask(startsInDraw: Bool) async throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.path = url.path
        sketch.startsInDraw = startsInDraw
        let sound = try flow()
        sketch.flow = sound
        let runtime = try makeRuntime(sketch)

        try await drive(runtime) { sketch.finished }

        // 修正の前に止まっていた条件を、実際に通っている
        #expect(sketch.detachedWhenCalled == [true])
        #expect(sketch.failure == nil, "失敗: \(String(describing: sketch.failure))")
        let song = try #require(sketch.song, "Task から頼んだ音が届いていない")
        // **足されている** — 足されていなければ、鳴らず解析もされない
        #expect(runtime.isAttached(song))
        song.play()
        let heard = try render(sound, 800)
        #expect(zip(heard, chord).map { abs($0 - $1) }.max() ?? 1 < 1e-6, "ファイルの頭からの音が鳴っていない")
        runtime.closePlugins()
    }

    @Test("止めている間 (noLoop()) に頼んでも、待ちは終わり、足された音が返る")
    func theWaitEndsWhileStopped() async throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.path = url.path
        sketch.stopsLooping = true
        sketch.flow = try flow()
        let runtime = try makeRuntime(sketch)

        try await drive(runtime) { sketch.finished }

        let song = try #require(sketch.song, "止めている間に頼んだ音が届いていない")
        #expect(runtime.isAttached(song))
        runtime.closePlugins()
    }

    @Test("読めないファイルは、loadSound と同じ失敗を投げ、足されない")
    func anUnreadableFileThrowsTheSameFailure() async throws {
        let url = try AudioOutsideRunTests.garbageFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.path = url.path
        let runtime = try makeRuntime(sketch)

        try await drive(runtime) { sketch.finished }

        #expect(sketch.song == nil)
        #expect(sketch.failure == .unreadable(path: url.path))
        runtime.closePlugins()
    }

    @Test("同じ Task の中の同期の loadSound は、これまでどおり notRunning を投げる")
    func synchronousLoadStillThrowsInATask() async throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.path = url.path
        sketch.alsoLoadsSynchronously = true
        sketch.flow = try flow()
        let runtime = try makeRuntime(sketch)

        try await drive(runtime) { sketch.finished }

        #expect(sketch.synchronousFailure == .notRunning(call: "loadSound(_:)"))
        #expect(sketch.song != nil, "同じ Task の中の requestSound が読めていない")
        runtime.closePlugins()
    }

    @Test("待っている最中に実行が畳まれたら、足されなかった音を返さず、notRunning を投げる")
    func closingWhileWaitingThrowsNotRunning() async throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Requesting()
        sketch.path = url.path
        sketch.flow = try flow()
        let runtime = try makeRuntime(sketch)
        // 最初のフレームで Task が起きる。以後はフレームを回さない — 頭で当てる者が居ない
        try runtime.advance()
        // 読み終えて窓口へ頼むまでは待つ (読むのは裏で、頭では当てない)
        let deadline = ContinuousClock.now + .seconds(30)
        while !runtime.attachRequests.hasWaiting, !sketch.finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(runtime.attachRequests.hasWaiting, "頼みが窓口に届いていない")
        runtime.closePlugins()
        // 待つ側が期限を持つ。畳んでも待ちが終わらなければ、ここで失敗にして返る
        let closedAt = ContinuousClock.now
        while !sketch.finished, ContinuousClock.now < closedAt + .seconds(10) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sketch.finished, "畳んだのに、待っている Task が終わらない")

        #expect(sketch.song == nil)
        #expect(sketch.failure == .notRunning(call: "requestSound(_:)"))
    }

    @Test("draw() の中で loadSound を呼ぶ警告は、requestSound(_:) へ案内する")
    func theBlockingLoadWarningPointsAtRequestSound() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        SoundSketch.onSetup = { _ in }
        SoundSketch.onDraw = { sketch in
            _ = try? sketch.loadSound(url.path)
        }
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice())
        try runtime.advance()
        let said = try #require(runtime.blockingLoads.message(for: "loadSound(_:)"), "警告が出ていない")
        #expect(said.contains("call requestSound(_:) from a Task started in setup()"))
        runtime.closePlugins()
    }
}
