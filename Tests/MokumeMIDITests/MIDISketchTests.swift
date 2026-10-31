// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeMIDI

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class MIDISketch: Sketch {
    nonisolated(unsafe) static var onSetup: (MIDISketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (MIDISketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// MIDI の入り口を、走っているスケッチの中で回す (#1963)。GPU を要する。
///
/// **どのメッセージがどのフレームの `draw()` に届くかが、フレームの数え方だけで決まる**ことが約束で、
/// これが水準 2 を名乗れる根拠になる (ADR-0028 決定 7)。
@Suite(
    "MIDI の入り口 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MIDISketchTests {
    private func run(frames: Int) throws {
        let runtime = try SketchRuntime(sketch: MIDISketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
    }

    @Test("setup() で作った記録の入り口は、最初の draw() から 1 組ずつ渡し、2 度回しても同じ")
    func recordedMessagesReachDrawInOrder() throws {
        let recorded: [[MIDIMessage]?] = [
            [.controlChange(channel: 1, controller: 1, value: 127), .noteOn(channel: 1, note: 60, velocity: 90)],
            nil, [.noteOff(channel: 1, note: 60, velocity: 0)],
        ]
        func record() throws -> [String] {
            var port: MIDIPort?
            var seen: [String] = []
            MIDISketch.onSetup = { port = $0.createMIDI(messages: recorded) }
            MIDISketch.onDraw = { _ in
                guard let port else { return }
                seen.append("\(port.messages) \(String(describing: port.controlChange(1))) \(port.state)")
            }
            try run(frames: 4)
            return seen
        }
        let first = try record()
        #expect(first.count == 4)
        #expect(first[0].hasSuffix("Optional(1.0) running"))
        #expect(first[1].hasSuffix("Optional(1.0) disconnected"))
        #expect(try record() == first)
    }

    @Test("開始の後に 1 フレーム 1 クロックを注入すると、24 個目が届いたフレームの draw() で拍が 1 になり、割り当てられたフレームが一致する (#3591)")
    func clockBeatReachesDrawOnItsFrame() throws {
        // 0 番目のフレームに開始、以降は 1 フレーム 1 クロック (24 個目は 24 番目のフレーム)
        let recorded: [[MIDIMessage]?] = [[.start]] + (1..<60).map { _ in [.clock] }
        func record() throws -> [String] {
            var port: MIDIPort?
            var seen: [String] = []
            MIDISketch.onSetup = { port = $0.createMIDI(messages: recorded) }
            MIDISketch.onDraw = { sketch in
                guard let port else { return }
                let arrived = port.report?.lastArrival.map { "\($0.frame == sketch.frameCount)" } ?? "none"
                seen.append("\(port.beat) \(arrived)")
            }
            try run(frames: 50)
            return seen
        }
        let first = try record()
        #expect(first.count == 50)
        #expect(first[0] == "0 true", "開始が届いたフレーム")
        #expect(first[23] == "0 true")
        #expect(first[24] == "1 true", "24 個目のクロックが届いたフレームで 0 から 1")
        #expect(first[47] == "1 true")
        #expect(first[48] == "2 true", "48 個目で 2")
        #expect(try record() == first, "何度回しても同じ")
    }

    @Test("外して足し直した記録の入り口は、外さずに回したときと同じメッセージを、足し直した後のフレームで受け取る (時刻どおり・#3152)")
    func reattachedPortKeepsTheTimeline() throws {
        // 要素ごとに違う CC の値。6 つで、10 フレームまで回すと最後まで行って最初に戻る
        let recorded: [[MIDIMessage]?] = (0..<6).map { [.controlChange(channel: 1, controller: 1, value: $0 + 1)] }
        func record(leaveAt: Int?, returnAt: Int?) throws -> [Int?] {
            var port: MIDIPort?
            var seen: [Int?] = []
            MIDISketch.onSetup = { port = $0.createMIDI(messages: recorded) }
            MIDISketch.onDraw = { sketch in
                guard let port else { return }
                if sketch.frameCount == leaveAt { sketch.detach(port) }
                if sketch.frameCount == returnAt { sketch.attach(port) }
                // このフレームに届いた CC (外している間は届かない)
                seen.append(
                    port.messages.compactMap {
                        if case .controlChange(_, _, let value) = $0 { value } else { nil }
                    }.last)
            }
            try run(frames: 10)
            return seen
        }
        let straight = try record(leaveAt: nil, returnAt: nil)
        let reattached = try record(leaveAt: 2, returnAt: 4)
        #expect(straight == [1, 2, 3, 4, 5, 6, 1, 2, 3, 4])
        // 外していた間 (3・4 フレーム目) は届かず、足し直した後 (5 フレーム目から) は外さない実行と同じ
        #expect(reattached[2] == nil && reattached[3] == nil)
        #expect(Array(reattached[4...]) == Array(straight[4...]), "\(reattached)")
    }
}

/// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外) から、MIDI の口を呼ぶ。
/// 走らせずに警告することを見るので、GPU は要らない。
@MainActor
@Suite("走っている実行の外から呼んだ MIDI の口")
struct MIDIOutsideRunTests {
    @Test("走っている実行の外から作ると、足されていない入り口を返し、呼んだ口の名前で 1 度だけ警告する")
    func outsideRunWarnsByItsOwnName() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = MIDISketch()
            for _ in 0..<2 {
                let port = sketch.createMIDI(messages: [[.controlChange(channel: 1, controller: 1, value: 5)]])
                // 足されていないので回されず、何も入らない
                #expect(port.state == .unavailable)
                #expect(port.controlChange(1) == nil)
            }
            #expect(log.messages.count == 1, "2 度呼んでも 1 行")
            #expect(log.messages.first?.contains("createMIDI(messages:)") == true, "\(log.messages)")
        }
    }
}
