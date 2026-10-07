// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。フレームレートを選べる。
final class MovieSketch: Sketch {
    nonisolated(unsafe) static var frameRate = 30
    nonisolated(unsafe) static var onSetup: (MovieSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (MovieSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: Self.frameRate) }
    func setup() { try? Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 1 フレームで動画から受け取ったもの。
struct MovieFrame: Equatable {
    var frame: Int
    var time: Float
    var isNewFrame: Bool
    /// 絵の画素 (作業空間の値)。
    var pixels: [LinearRGBA]
}

/// 動画を流す入り口 (#1960)。走っているスケッチの中で回すので GPU を要する。動画は検査の中で作る。
@Suite(
    "動画を流す入り口",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MovieTests {
    /// 固定の時計で `frames` フレーム回す。`now` は実時間の出どころ (固定の時計は読まないはず)。
    private func run(
        frames: Int, frameRate: Int = 30, now: @escaping () -> Double = { 0 },
        setup: @escaping (MovieSketch) throws -> Void,
        draw: @escaping (MovieSketch) -> Void = { _ in }
    ) throws -> SketchRuntime {
        MovieSketch.frameRate = frameRate
        MovieSketch.onSetup = setup
        MovieSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: MovieSketch(), gpu: try RenderDevice(), clock: nil, now: now)
        for _ in 0..<frames { try runtime.advance() }
        return runtime
    }

    /// 動画を作り、`setup()` で開いて `prepare` を当て、フレームごとに受け取ったものを返す。
    private func record(
        _ url: URL, frames: Int, frameRate: Int = 30, now: @escaping () -> Double = { 0 },
        prepare: @escaping (Movie) -> Void = { $0.loop() },
        during: @escaping (MovieSketch, Movie) -> Void = { _, _ in }
    ) throws -> [MovieFrame] {
        var movie: Movie?
        var received: [MovieFrame] = []
        let runtime = try run(
            frames: frames, frameRate: frameRate, now: now,
            setup: { sketch in
                let made = try sketch.createVideo(url.path)
                prepare(made)
                movie = made
            },
            draw: { sketch in
                guard let movie else { return }
                received.append(
                    MovieFrame(
                        frame: sketch.frameCount, time: movie.time, isNewFrame: movie.isNewFrame,
                        pixels: Self.pixels(of: movie.image)))
                during(sketch, movie)
            })
        runtime.closePlugins()
        return received
    }

    private static func pixels(of image: Image) -> [LinearRGBA] {
        (0..<image.height).flatMap { y in (0..<image.width).map { x in image.get(x, y) } }
    }

    /// 比べる相手 — 動画を別に頭から読んだ各コマを、同じ道 (`Image.write`) で絵にした画素。
    private func expectedPixels(_ url: URL) async throws -> [[LinearRGBA]] {
        let frames = try await TestMovie.reference(url)
        var pixels: [[LinearRGBA]] = []
        let runtime = try run(frames: 1, setup: { sketch in
            for frame in frames {
                let image = try sketch.createImage(frame.picture.width, frame.picture.height)
                image.write(frame.picture)
                pixels.append(Self.pixels(of: image))
            }
        })
        runtime.closePlugins()
        return pixels
    }

    // MARK: - 固定の時計 (水準 2)

    @Test("固定の時計では n 枚目に n−1 番目のコマが出て、実時間をでたらめに揺らしても変わらない")
    func fixedClockPicksFramesByFrameNumber() async throws {
        let url = try await TestMovie.write(frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await expectedPixels(url)
        #expect(expected.count == 30)

        // 30 fps の動画を 30 fps で 45 フレーム (1 秒で継ぎ目を越えて頭へ戻る)
        let steady = try record(url, frames: 45)
        #expect(steady.count == 45)
        for row in steady {
            let index = (row.frame - 1) % 30
            #expect(row.pixels == expected[index], "\(row.frame) 枚目に \(index) 番目のコマが出ていない")
            #expect(row.isNewFrame, "\(row.frame) 枚目")
        }

        // 実時間 (`now`) を毎回でたらめに飛ばしても、出るコマは同じ
        var jumps = [0.0, 7.3, 7.31, 120.0, 0.5, 3_000.0].makeIterator()
        let shaken = try record(url, frames: 45, now: { jumps.next() ?? Double.random(in: 0...10_000) })
        #expect(shaken == steady)
    }

    @Test("固定の時計で 2 度回すと、フレームごとのコマ・位置が一致する")
    func twoRunsMatch() async throws {
        let url = try await TestMovie.write(frames: 40, pixel: TestMovie.noise)
        defer { try? FileManager.default.removeItem(at: url) }
        // 60 fps の時計で、途中で止める・飛ぶ・流し直すを混ぜる
        let during: (MovieSketch, Movie) -> Void = { sketch, movie in
            switch sketch.frameCount {
            case 20: movie.pause()
            case 30: movie.jump(1.2)
            case 35: movie.play()
            case 70: movie.jump(0.2)
            default: break
            }
        }
        let first = try record(url, frames: 100, frameRate: 60, during: during)
        let second = try record(url, frames: 100, frameRate: 60, during: during)
        #expect(first.count == 100)
        #expect(first == second)
        // コマは実際に動いている (同じ絵が並んでいるだけではない)
        #expect(zip(first, first.dropFirst()).filter { $0.pixels != $1.pixels }.count > 10)
    }

    // MARK: - 操作

    @Test("作っただけでは流れず、最初のコマが映ったまま")
    func doesNotPlayUntilAsked() async throws {
        let url = try await TestMovie.write(frames: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await expectedPixels(url)
        let rows = try record(url, frames: 5, prepare: { _ in })
        #expect(rows.map(\.pixels) == Array(repeating: expected[0], count: 5))
        #expect(rows.map(\.isNewFrame) == [true, false, false, false, false])
        #expect(rows.map(\.time) == [0, 0, 0, 0, 0])
    }

    @Test("止めるとそのコマに留まり、飛ぶと次のフレームにその位置のコマが出る")
    func pauseAndJump() async throws {
        let url = try await TestMovie.write(frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await expectedPixels(url)
        var afterJump: Float?
        let rows = try record(
            url, frames: 12,
            during: { sketch, movie in
                if sketch.frameCount == 4 { movie.pause() }
                if sketch.frameCount == 8 {
                    movie.jump(20.0 / 30)
                    afterJump = movie.time
                }
            })
        // 1〜4 は流れ、5〜8 は 4 枚目のコマ (3 番目) のまま、9 から 20 番目のコマ
        for row in rows[0..<4] { #expect(row.pixels == expected[row.frame - 1]) }
        for row in rows[4..<8] { #expect(row.pixels == expected[3], "\(row.frame) 枚目") }
        for row in rows[8...] { #expect(row.pixels == expected[20], "\(row.frame) 枚目") }
        #expect(afterJump == Float(20.0 / 30), "飛ぶよう頼んだ直後の time は飛び先")
        #expect(rows[8].time == Float(20.0 / 30))
    }

    @Test("1 度だけ流すと終わりのコマで止まる")
    func playStopsOnTheLastFrame() async throws {
        let url = try await TestMovie.write(frames: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try await expectedPixels(url)
        let rows = try record(url, frames: 10, prepare: { $0.play() })
        for row in rows {
            #expect(row.pixels == expected[min(row.frame - 1, 5)], "\(row.frame) 枚目")
        }
        #expect(rows.last?.time == Float(6.0 / 30))
    }

    // MARK: - 状態と観測

    @Test("名乗りは動いている、閉じれば止まる。観測の名前はファイルの名前")
    func reportsRunningThenStopped() async throws {
        let url = try await TestMovie.write(frames: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        var movie: Movie?
        var arrivals: [Int?] = []
        let runtime = try run(
            frames: 3,
            setup: { sketch in
                movie = try sketch.createVideo(url.path)
                movie?.loop()
            },
            draw: { _ in arrivals.append(movie?.lastArrival?.frame) })
        #expect(arrivals == [1, 2, 3])
        #expect(movie?.state == .running)
        #expect(movie?.report?.name == "video: \(url.path)")
        #expect(movie?.width == 32 && movie?.height == 16)
        #expect(movie.map { abs($0.duration - Float(4.0 / 30)) < 1e-6 } == true)
        runtime.closePlugins()
        #expect(movie?.state == .stopped)
    }

    // MARK: - 作れないとき・読めなくなったとき

    @Test("見つからない・中身が動画でない・映像が無いときは、作るときに投げる")
    func failuresAreThrownAtCreation() throws {
        let garbage = try TestMovie.garbage()
        let sound = try TestMovie.soundOnly()
        defer {
            try? FileManager.default.removeItem(at: garbage)
            try? FileManager.default.removeItem(at: sound)
        }
        var failures: [MovieFailure] = []
        let runtime = try run(frames: 1, setup: { sketch in
            for file in ["no-such-movie.mov", garbage.path, sound.path] {
                do throws(MovieFailure) { _ = try sketch.createVideo(file) } catch { failures.append(error) }
            }
        })
        #expect(failures.count == 3)
        if case .notFound(let path, let searched) = failures.first {
            #expect(path == "no-such-movie.mov")
            #expect(!searched.isEmpty)
        } else {
            Issue.record("見つからないことが notFound にならない: \(failures)")
        }
        #expect(failures.dropFirst().first == .unreadable(path: garbage.path))
        #expect(failures.last == .noVideo(path: sound.path))
        #expect(failures.allSatisfy { !$0.description.isEmpty })
        runtime.closePlugins()
    }

    @Test("途中が壊れた動画は投げずに 1 度だけ知らせ、最後のコマを残して disconnected を名乗る")
    func damagedMiddleIsNoticedNotThrown() async throws {
        let url = try await TestMovie.write(frames: 60, width: 64, height: 48, pixel: TestMovie.noise)
        let broken = try TestMovie.damaged(url, from: 0.3, to: 0.6)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: broken)
        }
        var movie: Movie?
        var notices: [String] = []
        var states: [SourceState] = []
        var pixels: [[LinearRGBA]] = []
        let runtime = try run(
            frames: 60,
            setup: { sketch in
                let reader = try MovieReader(url: broken, path: "broken.mov")
                let made = Movie(
                    image: try sketch.createImage(reader.width, reader.height), reader: reader,
                    name: "video: broken.mov", owner: sketch, warn: { notices.append($0) })
                sketch.attach(made)
                made.loop()
                movie = made
            },
            draw: { sketch in
                guard let movie else { return }
                states.append(movie.state)
                pixels.append(Self.pixels(of: movie.image))
                // 50 枚目で頭へ飛ぶ
                if sketch.frameCount == 50 { movie.jump(0) }
            })
        let broke = try #require(states.firstIndex(of: .disconnected), "壊れた範囲で disconnected にならない")
        #expect(broke > 0)
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?.contains("broken.mov") == true)
        // 読めなくなった後も、最後に読めたコマが残る (黒や透明にならない)
        #expect(pixels[broke] == pixels[broke - 1])
        // 頭へ飛べば読み直して戻る
        #expect(states.last == .running)
        runtime.closePlugins()
    }

    @Test("数でない位置へ飛ぶと位置は変わらず、1 度だけ知らせる")
    func jumpToNotANumberIsNoticed() async throws {
        let url = try await TestMovie.write(frames: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        var notices: [String] = []
        var times: [Float] = []
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                let reader = try MovieReader(url: url, path: "clip.mov")
                let made = Movie(
                    image: try sketch.createImage(reader.width, reader.height), reader: reader,
                    name: "video: clip.mov", owner: sketch, warn: { notices.append($0) })
                sketch.attach(made)
                made.jump(.nan)
                made.jump(.infinity)
                times.append(made.time)
            })
        #expect(times == [0])
        #expect(notices.count == 1)
        #expect(notices.first?.contains("jump()") == true)
        runtime.closePlugins()
    }
}
