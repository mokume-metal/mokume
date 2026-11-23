// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 鳴らすだけの音は記録の保証の内で、**解析の値を読んだときだけ**名乗る (#3575 の完了条件 7)。音の待つ読み込みも名乗る。
///
/// ウィンドウの経路 (`onScreen: true`) は音を実時間で鳴らす。機材には出さず、manual rendering (offline) の流れを
/// 差し込んで回す。GPU を要する。
@Suite(
    "音の解析と記録",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplaySoundAnalysisTests {
    /// 公開の解析の読み。**1 つずつ確かめる** — どれか 1 つの名乗りが外れても、その行だけが赤になる。
    enum Read: String, CaseIterable, Sendable {
        case rms, decibels, peak, spectrum, level, spectrumLevels, energy, waveform, isBeat
    }

    /// 読む音の出どころ。
    enum Source: String, CaseIterable, Sendable {
        /// 合成音 (``SynthSound``)。理由には型の名前 (`TriOsc`) が載る。
        case synth
        /// 音声ファイル (``SoundFile``)。
        case file

        var kind: String { self == .synth ? "TriOsc" : "SoundFile" }
    }

    /// 音を 1 つ鳴らし、`read` が立っていれば 2 枚目でそれを `times` 回読むスケッチ。
    final class Reader: Sketch {
        var source = Source.synth
        var read: Read?
        var times = 1
        var flow: SoundFlow?
        var file: URL?
        var tone: TriOsc?
        var sound: SoundFile?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(_ source: Source, read: Read?, times: Int = 1, flow: SoundFlow?, file: URL?) {
            self.init()
            self.source = source
            self.read = read
            self.times = times
            self.flow = flow
            self.file = file
        }
        func setup() throws {
            switch source {
            case .synth:
                let made = TriOsc(stage: SynthStage.stage(for: self, flow: flow))
                made.play(440, 0.3)
                tone = made
            case .file:
                let made = try loadSound(try #require(file).path, flow: flow)
                made.play()
                sound = made
            }
        }
        func draw() {
            background(0, 0, 0)
            guard let read, frameCount == 2 else { return }
            for _ in 0..<times { take(read) }
        }
        private func take(_ read: Read) {
            switch read {
            case .rms: _ = (tone?.rms, sound?.rms)
            case .decibels: _ = (tone?.decibels, sound?.decibels)
            case .peak: _ = (tone?.peak, sound?.peak)
            case .spectrum: _ = (tone?.spectrum, sound?.spectrum)
            case .level: _ = (tone?.level, sound?.level)
            case .spectrumLevels: _ = (tone?.spectrumLevels, sound?.spectrumLevels)
            case .energy: _ = (tone?.energy(from: 20, to: 140), sound?.energy(from: 20, to: 140))
            case .waveform: _ = (tone?.waveform, sound?.waveform)
            case .isBeat: _ = (tone?.isBeat, sound?.isBeat)
            }
        }
    }

    /// 録る。`onScreen` ならウィンドウの経路で、音は差し込んだ流れで鳴る。
    private func record(
        _ source: Source = .synth, read: Read?, times: Int = 1, onScreen: Bool, to url: URL, file: URL? = nil
    ) throws -> ReplayRecord {
        let flow = onScreen ? try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096) : nil
        let sketch = Reader(source, read: read, times: times, flow: flow, file: file)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            now: { 0 }, onScreen: onScreen, persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        return try ReplayRecord.read(from: url)
    }

    /// ウィンドウなしで流す。
    private func replay(read: Read?, _ url: URL) throws -> ReplayPlayer.Report {
        let record = try ReplayRecord.read(from: url)
        let player = ReplayPlayer(record: record, source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: Reader(.synth, read: read, flow: nil, file: nil), gpu: RenderDevice(),
            clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false, opensFacets: false,
            handover: nil)
        runtime.startReplaying(player)
        var advances = 0
        while !player.isFinished, advances < 20 {
            player.beginAdvance(at: Double(advances))
            try runtime.advance()
            advances += 1
        }
        let report = try #require(runtime.finishReplaying())
        runtime.closePlugins()
        return report
    }

    @Test("鳴らすだけの音は、ウィンドウで録っても名乗らない。level を 1 度読むと、音の印が 1 つ付き、流す側も名乗る")
    func onlyAnAnalysisReadIsNamed() throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let analysis = ReplayRecorder.Reason.soundAnalysis("TriOsc")

        let quiet = directory.appendingPathComponent("quiet.json")
        let plain = try record(read: nil, onScreen: true, to: quiet)
        #expect(plain.window && plain.unreproducible.isEmpty, "\(plain.unreproducible)")
        #expect(try replay(read: nil, quiet).unreproducible.isEmpty)

        let read = directory.appendingPathComponent("read.json")
        let named = try record(read: .level, onScreen: true, to: read)
        #expect(named.unreproducible == [analysis], "\(named.unreproducible)")
        #expect(try replay(read: .level, read).unreproducible == [analysis])

        // 記録の理由を消しても、ウィンドウで録った記録を流す側が、読んだときに自分で名乗る
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: read)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = directory.appendingPathComponent("stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        #expect(try replay(read: .level, copy).unreproducible == [analysis])
    }

    @Test(
        "合成音と音声ファイルの公開の解析の読みは、どれを読んでもウィンドウで録った記録が音の解析を名乗る",
        arguments: Source.allCases, Read.allCases)
    func everyAnalysisReadIsNamed(source: Source, read: Read) throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = source == .file ? try writeWAV(chord, sampleRate: 48_000) : nil
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        let url = directory.appendingPathComponent("\(source)-\(read).json")
        let named = try record(source, read: read, onScreen: true, to: url, file: file)
        #expect(
            named.unreproducible == [ReplayRecorder.Reason.soundAnalysis(source.kind)],
            "\(source).\(read): \(named.unreproducible)")
    }

    @Test("1 フレームに解析の値を何百回読んでも、記録の理由は 1 つ")
    func manyReadsAreNamedOnce() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("many.json")
        let taken = try record(read: .level, times: 300, onScreen: true, to: url)
        #expect(taken.unreproducible == [ReplayRecorder.Reason.soundAnalysis("TriOsc")], "\(taken.unreproducible)")
    }

    @Test("ウィンドウなしで録った記録は、解析の値を読んでも名乗らない (流す側と同じくフレームの数で進む)")
    func aHeadlessRecordIsNotNamed() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("headless.json")
        let taken = try record(read: .level, onScreen: false, to: url)
        #expect(!taken.window && taken.unreproducible.isEmpty, "\(taken.unreproducible)")
        let report = try replay(read: .level, url)
        #expect(report.unreproducible.isEmpty && report.matched, "\(report.unreproducible)")
    }

    // MARK: - 音の時計 (#4096)

    /// 公開の、音の時計に依る読み。**1 つずつ確かめる**。
    enum ClockRead: String, CaseIterable, Sendable {
        case soundTime, position, isPlaying

        /// 理由に載る読み手の名前。
        var reader: String {
            switch self {
            case .soundTime: "soundTime"
            case .position: "SoundFile.position"
            case .isPlaying: "SoundFile.isPlaying"
            }
        }
    }

    /// 合成音と音声ファイルを 1 つずつ鳴らし続け (ファイルは `loop()`)、`read` が立っていれば毎フレームそれを読むスケッチ。
    final class ClockReader: Sketch {
        var read: ClockRead?
        var flow: SoundFlow?
        var file: URL?
        var tone: TriOsc?
        var sound: SoundFile?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(read: ClockRead?, flow: SoundFlow?, file: URL) {
            self.init()
            self.read = read
            self.flow = flow
            self.file = file
        }
        func setup() throws {
            let made = TriOsc(stage: SynthStage.stage(for: self, flow: flow))
            made.play(440, 0.3)
            tone = made
            let loaded = try loadSound(try #require(file).path, flow: flow)
            loaded.loop()
            sound = loaded
        }
        /// 2 枚目で `jump(.nan)` を呼ぶ (断られて警告だけが出る)。
        var jumpsToNaN = false
        private(set) var jumped = false
        func draw() {
            background(0, 0, 0)
            if jumpsToNaN, frameCount == 2 {
                sound?.jump(.nan)
                jumped = true
            }
            switch read {
            case .soundTime: _ = soundTime
            case .position: _ = sound?.position
            case .isPlaying: _ = sound?.isPlaying
            case nil: break
            }
        }
    }

    /// 時計を読むスケッチを録る。`onScreen` ならウィンドウの経路で、音は差し込んだ流れで鳴る。
    private func recordClock(_ read: ClockRead?, onScreen: Bool, to url: URL, file: URL) throws -> ReplayRecord {
        let flow = onScreen ? try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096) : nil
        let runtime = try SketchRuntime(
            sketch: ClockReader(read: read, flow: flow, file: file), gpu: RenderDevice(),
            clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: onScreen, persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        return try ReplayRecord.read(from: url)
    }

    /// 時計を読むスケッチの記録を、ウィンドウなしで流す。
    private func replayClock(_ read: ClockRead?, _ url: URL, file: URL) throws -> ReplayPlayer.Report {
        let player = ReplayPlayer(record: try ReplayRecord.read(from: url), source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: ClockReader(read: read, flow: nil, file: file), gpu: RenderDevice(),
            clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false, opensFacets: false,
            handover: nil)
        runtime.startReplaying(player)
        var advances = 0
        while !player.isFinished, advances < 20 {
            player.beginAdvance(at: Double(advances))
            try runtime.advance()
            advances += 1
        }
        let report = try #require(runtime.finishReplaying())
        runtime.closePlugins()
        return report
    }

    @Test(
        "音の時計に依る値を毎フレーム読むと、ウィンドウで録った記録に理由がちょうど 1 つ載り、流す側も同じ理由を名乗る",
        arguments: ClockRead.allCases)
    func aClockReadIsNamedOnce(read: ClockRead) throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = directory.appendingPathComponent("clock-\(read).json")
        let reason = ReplayRecorder.Reason.soundClock(read.reader)
        let taken = try recordClock(read, onScreen: true, to: url, file: file)
        #expect(taken.window && taken.unreproducible == [reason], "\(read): \(taken.unreproducible)")
        let report = try replayClock(read, url, file: file)
        #expect(report.unreproducible == [reason], "\(read): \(report.unreproducible)")

        // 記録の理由を消しても、ウィンドウで録った記録を流す側が、読んだときに自分で名乗る
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = directory.appendingPathComponent("clock-\(read)-stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        let found = try replayClock(read, copy, file: file)
        #expect(found.unreproducible == [reason], "流す側が自分で見つける: \(read): \(found.unreproducible)")
    }

    @Test("jump(_:) に数でない値を渡した警告は位置を文面に載せるが、時計の読みとして名乗らない")
    func aJumpWarningIsNotAClockRead() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("clock-jump.json")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let sketch = ClockReader(read: nil, flow: flow, file: file)
        sketch.jumpsToNaN = true
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: true,
            persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        let taken = try ReplayRecord.read(from: url)
        #expect(sketch.jumped, "jump(.nan) を呼んだ")
        #expect(taken.window && taken.unreproducible.isEmpty, "\(taken.unreproducible)")
    }

    // MARK: - 資源のハッシュ (#4092)

    @Test("loadSound(_:) で読んだ音声ファイルを記録の後に書き換えて流すと、資源のハッシュが違うと名乗り、書き換えなければ名乗らない")
    func aChangedSoundFileIsNamedWhenReplayed() throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = directory.appendingPathComponent("sound-resource.json")
        let taken = try recordClock(nil, onScreen: false, to: url, file: file)
        #expect(taken.unreproducible.isEmpty && taken.resources.keys.sorted() == [file.path], "\(taken.resources)")

        let same = try replayClock(nil, url, file: file)
        #expect(same.unreproducible.isEmpty && same.matched, "\(same.unreproducible)")

        // 同じ場所を別の音で書き換える (音は鳴らすだけで描かないので、matched は真のまま)
        let other = try writeWAV(chord.map { $0 * 0.5 }, sampleRate: 48_000)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
        let changed = try replayClock(nil, url, file: file)
        #expect(
            changed.unreproducible == [ReplayRecorder.Reason.resourceDiffers(file.path)],
            "\(changed.unreproducible)")
        #expect(changed.matched)
    }

    /// `loadSound` のほかに音声ファイルを読む口。
    enum SoundOpener: String, CaseIterable, Sendable {
        case requestSound, audioIn
    }

    /// 音声ファイルを 1 度開くスケッチ (`requestSound` は `Task` で)。
    final class SoundOpenerSketch: Sketch {
        var opener = SoundOpener.requestSound
        var path = ""
        var loading: Task<Void, Never>?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(_ opener: SoundOpener, path: String) {
            self.init()
            self.opener = opener
            self.path = path
        }
        func setup() throws {
            switch opener {
            case .requestSound: loading = Task { [self] in _ = try? await requestSound(path) }
            case .audioIn: _ = try createAudioIn(file: path)
            }
        }
        func draw() { background(0, 0, 0) }
    }

    @Test(
        "requestSound(_:) と createAudioIn(file:) で開いた音声ファイルも、記録の後に書き換えて流すと資源のハッシュが違うと名乗る",
        arguments: SoundOpener.allCases)
    func aChangedSoundFileOpenedOtherwiseIsNamed(opener: SoundOpener) async throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = directory.appendingPathComponent("opener-\(opener).json")

        // 受け手が名乗りを受け終える (`noted` が真になる) まで待つ。`requestSound` はフレームの頭で足し終えるまで
        // 返らないので、`Task` の終わりではなく、足す前の名乗りそのもの (受け手が控えた資源の数) を待つ。
        // **待つ側が期限を持つ**
        func wait(until noted: () -> Bool, advancing runtime: SketchRuntime?) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !noted() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("30 秒たっても資源の名乗りが届かない (\(opener))")
                    return
                }
                try runtime?.advance()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let recorder = try SketchRuntime(
            sketch: SoundOpenerSketch(opener, path: file.path), gpu: RenderDevice(),
            clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false)
        try #require(recorder.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
        try recorder.advance()
        try await wait(until: { recorder.replay?.resources.count == 1 }, advancing: recorder)
        for _ in 0..<2 { try recorder.advance() }
        recorder.closePlugins()
        let taken = try ReplayRecord.read(from: url)
        // `requestSound` は待つ読み込みを、`createAudioIn(file:)` は外から値が届く入り口 (音声ファイル) を名乗る
        let waiting =
            opener == .requestSound
            ? [ReplayRecorder.Reason.waitingLoad] : [ReplayRecorder.Reason.outsideInput("audio file: \(file.path)")]
        #expect(taken.unreproducible == waiting, "\(taken.unreproducible)")
        #expect(taken.resources.keys.sorted() == [file.path], "\(taken.resources)")

        // 流すのは記録の終わりまで。読み込みが記録より遅く届いても、報告を書く前に名乗り終えるのを待つ
        func replay() async throws -> ReplayPlayer.Report {
            let record = try ReplayRecord.read(from: url)
            let player = ReplayPlayer(record: record, source: url.path, reportURL: nil)
            let runtime = try SketchRuntime(
                sketch: SoundOpenerSketch(opener, path: file.path), gpu: RenderDevice(),
                clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false,
                opensFacets: false, handover: nil)
            runtime.startReplaying(player)
            // 記録の枚数は、録っている間に読み込みが届くまでの時間で決まる。期限は記録の長さから回数で持つ
            var advances = 0
            while !player.isFinished, advances < record.steps.count * 2 + 10 {
                player.beginAdvance(at: Double(advances))
                try runtime.advance()
                advances += 1
                if player.resourcesRead == 0 { try await Task.sleep(for: .milliseconds(5)) }
            }
            try #require(player.isFinished, "記録の終わりまで流せなかった")
            try await wait(until: { player.resourcesRead == 1 }, advancing: nil)
            let report = try #require(runtime.finishReplaying())
            runtime.closePlugins()
            return report
        }
        let same = try await replay()
        #expect(same.unreproducible == waiting && same.matched, "\(same.unreproducible)")

        let other = try writeWAV(chord.map { $0 * 0.5 }, sampleRate: 48_000)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
        let changed = try await replay()
        #expect(
            changed.unreproducible == waiting + [ReplayRecorder.Reason.resourceDiffers(file.path)],
            "\(changed.unreproducible)")
    }

    /// `loadSound` で読んだ音を 4 枚目で外し、8 枚目で足し直して鳴らす (器を読み直す) スケッチ。
    final class Reattaching: Sketch {
        var path = ""
        var flow: SoundFlow?
        var sound: SoundFile?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(path: String, flow: SoundFlow) {
            self.init()
            self.path = path
            self.flow = flow
        }
        func setup() throws {
            sound = try loadSound(path, flow: flow)
            sound?.loop()
        }
        func draw() {
            background(0, 0, 0)
            guard let sound else { return }
            if frameCount == 4 { detach(sound) }
            if frameCount == 8 {
                attach(sound)
                sound.loop()
            }
        }
    }

    @Test("外して足し直した音の読み直しもハッシュの口を通り、同じ名前で照らす: 変わらなければ控えに当たって取り直さず、変われば記録が名乗る")
    func aReloadedSoundFileIsHashedUnderTheSameName() throws {
        ResourceHasher.startCounting()
        let directory = try TestScratch.directory("mokume-replay-sound")
        func take(_ file: URL, rewrites: Bool, to url: URL) throws -> ReplayRecord {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            let runtime = try SketchRuntime(
                sketch: Reattaching(path: file.path, flow: flow), gpu: RenderDevice(),
                clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false)
            try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
            for frame in 1...10 {
                try runtime.advance()
                if frame == 6, rewrites {
                    // 外している間に、同じ長さ・同じ形式の別の音へ書き換える
                    let other = try writeWAV(chord.map { $0 * 0.5 }, sampleRate: 48_000)
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
                }
            }
            runtime.closePlugins()
            return try ReplayRecord.read(from: url)
        }

        // 対照: 書き換えなければ、読み直しは控えに当たって取り直さず、名乗らない
        let quietFile = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: quietFile) }
        let quiet = try take(quietFile, rewrites: false, to: directory.appendingPathComponent("reload-quiet.json"))
        #expect(quiet.unreproducible.isEmpty, "\(quiet.unreproducible)")
        #expect(quiet.resources.keys.sorted() == [quietFile.path])
        #expect(ResourceHasher.timesTaken(for: quietFile.path) == 1, "読み直しは控えに当たる")

        // 書き換えると、読み直しが同じ名前で別のハッシュを名乗り、記録が「実行中に変わった」を名乗る
        let changing = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: changing) }
        let changed = try take(changing, rewrites: true, to: directory.appendingPathComponent("reload-changed.json"))
        #expect(
            changed.unreproducible == [ReplayRecorder.Reason.resourceChanged(changing.path)], "\(changed.unreproducible)")
        #expect(ResourceHasher.timesTaken(for: changing.path) == 2, "最初の読みと、書き換えた後の読み直し")
    }

    @Test("音を鳴らし続けるだけで時計を読まない作品は、ウィンドウで録っても名乗らない")
    func playingWithoutAClockReadIsNotNamed() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("clock-quiet.json")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let taken = try recordClock(nil, onScreen: true, to: url, file: file)
        #expect(taken.window && taken.unreproducible.isEmpty, "\(taken.unreproducible)")
    }

    @Test("ウィンドウなしで録った記録は、音の時計に依る値を読んでも名乗らない", arguments: ClockRead.allCases)
    func aHeadlessClockReadIsNotNamed(read: ClockRead) throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = directory.appendingPathComponent("clock-headless-\(read).json")
        let taken = try recordClock(read, onScreen: false, to: url, file: file)
        #expect(!taken.window && taken.unreproducible.isEmpty, "\(read): \(taken.unreproducible)")
        let report = try replayClock(read, url, file: file)
        #expect(report.unreproducible.isEmpty && report.matched, "\(read): \(report.unreproducible)")
    }

    // MARK: - 待つ読み込み

    /// `setup()` で起こした `Task` から、在らない音声ファイルを `requestSound(_:)` で頼むスケッチ。
    final class SoundRequester: Sketch {
        var loading: Task<Void, Never>?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        func setup() {
            // 在らない名前でよい。名乗るのは、待つ読み込みの API を使ったことである
            loading = Task { [self] in _ = try? await requestSound("missing.wav") }
        }
        func draw() { background(0, 0, 0) }
    }

    @Test("requestSound(_:) を使うと、記録が「待つ読み込み」を名乗る")
    func requestSoundIsNamed() async throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("request.json")
        let sketch = SoundRequester()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false,
            persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path, generation: false))))
        for frame in 1...3 {
            try runtime.advance()
            if frame == 1 { await sketch.loading?.value }
        }
        runtime.closePlugins()
        let record = try ReplayRecord.read(from: url)
        #expect(record.unreproducible == [ReplayRecorder.Reason.waitingLoad], "\(record.unreproducible)")
    }
}

/// 音 1 つの解析の名乗り (``SoundAnalysisNotice``) が、受け手ごとに 1 度だけ理由を組んで渡すこと。
///
/// 受け手を数える偽物に差し替え、解析の値の置き場 (``DeferredLevels``) を直に読む。GPU も音の機材も要らない。
@Suite("音の解析の名乗りと受け手")
@MainActor
struct SoundAnalysisNoticeTests {
    /// 渡された理由と、ウィンドウかを訊かれた回数を数える受け手。検査の main actor の上でだけ触る。
    final class CountingSink: UnreproducibleSink, @unchecked Sendable {
        let window: Bool
        private(set) var reasons: [String] = []
        private(set) var windowQueries = 0
        init(window: Bool) { self.window = window }
        func noteUnreproducible(_ reason: String) { reasons.append(reason) }
        func noteResource(_ name: String, sha256: String) {}
        let resourceDigests = ResourceDigests()
        var soundRunsInRealTime: Bool {
            windowQueries += 1
            return window
        }
    }

    private let reason = ReplayRecorder.Reason.soundAnalysis("TriOsc")

    /// `sink` を受け手にして、解析の読みの口 3 つを `times` 回ずつ読む。
    private func read(_ levels: inout DeferredLevels, by sink: CountingSink, times: Int = 1) {
        LaunchingSketch.$replay.withValue(sink) {
            for _ in 0..<times {
                _ = levels.levels()
                _ = levels.waveform()
                _ = levels.isBeat
            }
        }
    }

    @Test("同じ音を 2 つの受け手 (記録とその後の別の記録・記録と再生) で読むと、それぞれへ 1 度ずつ名乗る")
    func eachSinkIsNamedOnce() {
        var levels = DeferredLevels(replayKind: "TriOsc")
        let first = CountingSink(window: true)
        let second = CountingSink(window: true)
        read(&levels, by: first, times: 3)
        read(&levels, by: second, times: 3)
        #expect(first.reasons == [reason], "\(first.reasons)")
        #expect(second.reasons == [reason], "受け手が変わったら名乗り直す: \(second.reasons)")
    }

    @Test("1 つの受け手に何百回読んでも、理由を組んで渡すのは 1 回")
    func manyReadsReachTheSinkOnce() {
        var levels = DeferredLevels(replayKind: "TriOsc")
        let sink = CountingSink(window: true)
        read(&levels, by: sink, times: 300)
        #expect(sink.reasons.count == 1)
    }

    @Test("ウィンドウでない受け手は 1 度だけ訊いて名乗らず、その後のウィンドウの受け手には名乗る")
    func aHeadlessSinkIsAskedOnceThenAWindowSinkIsNamed() {
        var levels = DeferredLevels(replayKind: "TriOsc")
        let headless = CountingSink(window: false)
        read(&levels, by: headless, times: 100)
        #expect(headless.reasons.isEmpty)
        #expect(headless.windowQueries == 1, "名乗らないと決めた受け手には、読むたびに訊き直さない")
        let window = CountingSink(window: true)
        read(&levels, by: window)
        #expect(window.reasons == [reason], "\(window.reasons)")
    }

    @Test("音の時計の名乗りは、受け手ごとに 1 度だけ理由を渡し、ウィンドウでない受け手には 1 度だけ訊いて名乗らない")
    func aClockNoticeIsNamedOncePerSink() {
        var notice = SoundClockNotice(reader: "SoundFile.position")
        let headless = CountingSink(window: false)
        LaunchingSketch.$replay.withValue(headless) {
            for _ in 0..<100 { notice.noteRead() }
        }
        #expect(headless.reasons.isEmpty && headless.windowQueries == 1, "\(headless.reasons)")
        let window = CountingSink(window: true)
        LaunchingSketch.$replay.withValue(window) {
            for _ in 0..<300 { notice.noteRead() }
        }
        #expect(window.reasons == [ReplayRecorder.Reason.soundClock("SoundFile.position")], "\(window.reasons)")
        #expect(window.windowQueries == 1)
    }

    @Test("名乗る種類を持たない置き場は、受け手が居ても名乗らない")
    func aKindlessHolderIsSilent() {
        var levels = DeferredLevels()
        let sink = CountingSink(window: true)
        read(&levels, by: sink)
        #expect(sink.reasons.isEmpty && sink.windowQueries == 0)
    }
}
