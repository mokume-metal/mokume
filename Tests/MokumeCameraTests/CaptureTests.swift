// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCamera
import MokumeCore

/// 何もしない出どころ。状態だけを始まりに置き、絵は 1 枚も入れない。
final class SilentSource: CaptureSource {
    let initial: SourceState
    private(set) var stopped = 0
    init(_ initial: SourceState) { self.initial = initial }
    func start(into input: ExternalInput<DisplayImage>) { input.setState(initial) }
    func pump(into input: ExternalInput<DisplayImage>) {}
    func stop() { stopped += 1 }
}

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class CaptureSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (CaptureSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (CaptureSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { try? Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 1 色で埋めた 4x4。
private func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> DisplayImage {
    DisplayImage(
        width: 4, height: 4,
        bytes: Array(repeating: [red, green, blue, 255], count: 16).flatMap { $0 })
}

/// カメラの入り口 (#1977)。走っているスケッチの中で回すので GPU を要する。
@Suite(
    "カメラの入り口",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CaptureTests {
    private func run(
        frames: Int, setup: @escaping (CaptureSketch) throws -> Void,
        draw: @escaping (CaptureSketch) -> Void = { _ in }
    ) throws -> SketchRuntime {
        CaptureSketch.onSetup = setup
        CaptureSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: CaptureSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
        return runtime
    }

    /// 注入の道 (ADR-0028 決定 6)。同じ列からは同じ絵が同じフレームに出る (決定 7)。
    @Test("記録した列が、フレームごとに 1 枚ずつ順に image へ入る")
    func framesArriveInOrder() throws {
        var camera: Capture?
        var seen: [Float] = []
        var arrivals: [Int?] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                camera = try sketch.createCapture(frames: [solid(255, 0, 0), solid(0, 0, 255)])
            },
            draw: { sketch in
                guard let camera else { return }
                #expect(camera.isNewFrame)
                seen.append(camera.image.get(0, 0).red)
                arrivals.append(camera.lastArrival?.frame)
            })
        // 赤 → 青 → 赤 → 青 (線形の値で赤は 1、青の赤成分は 0)
        #expect(seen == [1, 0, 1, 0])
        // 届いた絵は、取り出したフレームに割り当てられる
        #expect(arrivals == [1, 2, 3, 4])
        #expect(camera?.state == .running)
        #expect(camera?.report?.name == "camera (frames)")
        runtime.closePlugins()
        #expect(camera?.state == .stopped)
    }

    @Test("同じ列を 2 度回すと、同じフレームに同じ絵が出る")
    func sameFramesSameResult() throws {
        func record() throws -> [Float] {
            var camera: Capture?
            var seen: [Float] = []
            let runtime = try run(
                frames: 5,
                setup: { camera = try $0.createCapture(frames: [solid(255, 0, 0), solid(0, 255, 0), solid(0, 0, 255)]) },
                draw: { _ in seen.append(camera?.image.get(0, 0).green ?? -1) })
            runtime.closePlugins()
            return seen
        }
        #expect(try record() == record())
    }

    @Test("列が空なら作れない")
    func emptyFramesThrow() throws {
        var failure: (any Error)?
        let runtime = try run(frames: 1, setup: { sketch in
            do { _ = try sketch.createCapture(frames: []) } catch { failure = error }
        })
        #expect(failure is ImageFailure)
        runtime.closePlugins()
    }

    @Test("stop() で閉じ、以後は絵が変わらない")
    func stopCloses() throws {
        var camera: Capture?
        var seen: [Float] = []
        let runtime = try run(
            frames: 4,
            setup: { camera = try $0.createCapture(frames: [solid(255, 0, 0), solid(0, 0, 255)]) },
            draw: { sketch in
                seen.append(camera?.image.get(0, 0).red ?? -1)
                if sketch.frameCount == 2 { camera?.stop() }
            })
        // 3 と 4 では供給されないので、2 の青のまま
        #expect(seen == [1, 0, 0, 0])
        #expect(camera?.state == .stopped)
        runtime.closePlugins()
    }

    // MARK: - 来ないときの知らせ

    /// 時計と知らせを差し替えた入り口を、`setup()` で足す。
    private func stuck(
        _ state: SourceState, clock: @escaping () -> Double, notices: @escaping (String) -> Void
    ) -> (CaptureSketch) throws -> Void {
        { sketch in
            let capture = Capture(
                image: try sketch.createImage(4, 4), device: nil, name: "camera",
                source: SilentSource(state), owner: sketch, now: clock, warn: notices)
            sketch.attach(capture)
        }
    }

    @Test("許可を待ったまま 3 秒経っても来なければ、どのアプリの許可かを 1 度だけ言う")
    func waitingTooLongIsNoticedOnce() throws {
        var now = 0.0
        var notices: [String] = []
        let runtime = try run(
            frames: 5, setup: stuck(.waitingForPermission, clock: { now }, notices: { notices.append($0) }),
            draw: { sketch in now = Double(sketch.frameCount) * 1.5 })
        // 開いたのは 0 秒。1.5・3.0 秒目の供給はまだ (3.0 は draw の後に進む)、4.5 秒目で言う
        #expect(notices.count == 1)
        #expect(notices.first?.contains("System Settings > Privacy & Security > Camera") == true)
        runtime.closePlugins()
    }

    @Test("3 秒経つ前には言わない")
    func waitingBrieflyIsQuiet() throws {
        var notices: [String] = []
        let runtime = try run(
            frames: 5, setup: stuck(.waitingForPermission, clock: { 2.9 }, notices: { notices.append($0) }))
        #expect(notices.isEmpty)
        runtime.closePlugins()
    }

    @Test("拒まれていれば、すぐに 1 度だけ言う")
    func deniedIsNoticedOnce() throws {
        var notices: [String] = []
        let runtime = try run(
            frames: 3, setup: stuck(.denied, clock: { 0 }, notices: { notices.append($0) }))
        #expect(notices.count == 1)
        #expect(notices.first?.contains("denied") == true)
        runtime.closePlugins()
    }
}

/// 許可を問われるアプリの名指し。GPU は要らない。
@Suite("許可を問われるアプリ")
struct ResponsibleAppTests {
    @Test("束ねた .app ならそれ自身、端末からなら起動したアプリ、それも無ければ端末の名前")
    func namesTheAppThatIsAsked() {
        #expect(Capture.responsibleApp(bundle: "org.example.sketch", environment: [:]) == "org.example.sketch")
        #expect(
            Capture.responsibleApp(
                bundle: nil,
                environment: ["__CFBundleIdentifier": "com.apple.Terminal", "TERM_PROGRAM": "Apple_Terminal"])
                == "com.apple.Terminal")
        #expect(Capture.responsibleApp(bundle: nil, environment: ["TERM_PROGRAM": "vscode"]) == "vscode")
        #expect(Capture.responsibleApp(bundle: nil, environment: [:]) == "the app that started this sketch")
    }
}
