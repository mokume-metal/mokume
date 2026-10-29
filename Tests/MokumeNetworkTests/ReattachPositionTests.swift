// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class ReplaySketch: Sketch {
    nonisolated(unsafe) static var onSetup: (ReplaySketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (ReplaySketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 記録した列を流す 7 つの作る口を、外して足し直したときの位置 (#3152)。走っているスケッチの中で回すので GPU を要する。
///
/// **足し直した後のフレームには、外さずに回した実行と同じ束が入る** (時刻どおり)。外していた間も作品のフレームは
/// 進んでいたものとして数え、外していた間の束は届かない。列は要素ごとに違う値にする — 同じ値の列では、
/// 頭から・続きから・時刻どおりの違いが見えない。
@Suite(
    "記録した列を流すネットワークの口 (外して足し直した位置)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ReattachPositionTests {
    /// 7 つの作る口。`values[i]` を i 番目の束に入れた入り口と、その時点で届いている束を読む手続きを返す。
    private static let makers: [(name: String, make: (ReplaySketch, [Int]) -> (any Inlet, () -> String))] = [
        (
            "createOSC(messages:)",
            { sketch, values in
                let port = sketch.createOSC(messages: values.map { [OSCMessage("/m", $0)] })
                return (port, { port.messages.map { "\($0)" }.joined(separator: ",") })
            }
        ),
        (
            "createTCPServer(messages:)",
            { sketch, values in
                let port = sketch.createTCPServer(messages: values.map { [String($0)] })
                return (port, { port.messages.joined(separator: ",") })
            }
        ),
        (
            "createTCPClient(messages:)",
            { sketch, values in
                let port = sketch.createTCPClient(messages: values.map { [String($0)] })
                return (port, { port.messages.joined(separator: ",") })
            }
        ),
        (
            "createWebSocketServer(messages:)",
            { sketch, values in
                let port = sketch.createWebSocketServer(messages: values.map { [String($0)] })
                return (port, { port.messages.joined(separator: ",") })
            }
        ),
        (
            "createWebSocketClient(messages:)",
            { sketch, values in
                let port = sketch.createWebSocketClient(messages: values.map { [String($0)] })
                return (port, { port.messages.joined(separator: ",") })
            }
        ),
        (
            "createUDP(messages:)",
            { sketch, values in
                let port = sketch.createUDP(messages: values.map { [String($0)] })
                return (port, { port.messages.joined(separator: ",") })
            }
        ),
        (
            "createSerial(lines:)",
            { sketch, values in
                let port = sketch.createSerial(lines: values.map { [String($0)] })
                return (port, { port.lines.joined(separator: ",") })
            }
        ),
    ]

    /// 10 フレーム回し、フレームごとに届いている束を集める。`leaveAt` フレーム目の `draw()` で外し、`returnAt`
    /// フレーム目の `draw()` で足し直す (外さない実行は `nil`)。
    private func record(
        _ make: @escaping (ReplaySketch, [Int]) -> (any Inlet, () -> String), values: [Int], leaveAt: Int?,
        returnAt: Int?
    ) throws -> [String] {
        var inlet: (any Inlet)?
        var read: () -> String = { "" }
        var seen: [String] = []
        ReplaySketch.onSetup = { sketch in
            let made = make(sketch, values)
            inlet = made.0
            read = made.1
        }
        ReplaySketch.onDraw = { sketch in
            guard let inlet else { return }
            if sketch.frameCount == leaveAt { sketch.detach(inlet) }
            if sketch.frameCount == returnAt { sketch.attach(inlet) }
            seen.append(read())
        }
        let runtime = try SketchRuntime(sketch: ReplaySketch(), gpu: try RenderDevice())
        for _ in 0..<10 { try runtime.advance() }
        runtime.closePlugins()
        return seen
    }

    @Test("外して足し直した記録のポートは、外さずに回したときと同じ束を、足し直した後のフレームで受け取る (7 口・時刻どおり・#3152)")
    func reattachedRecordedPortKeepsTheTimeline() throws {
        // 要素ごとに違う値の 6 束。10 フレームまで回すと最後まで行って最初に戻る
        let values = [10, 11, 12, 13, 14, 15]
        for (name, make) in Self.makers {
            let straight = try record(make, values: values, leaveAt: nil, returnAt: nil)
            let reattached = try record(make, values: values, leaveAt: 2, returnAt: 4)
            // 外さない実行では、i 番目のフレームに i 番目の束が入り、最後まで行けば最初に戻る
            #expect(straight.count == 10 && Set(straight[0..<6]).count == 6, "\(name): \(straight)")
            #expect(straight[6] == straight[0], "\(name): \(straight)")
            // 足し直した後 (5 フレーム目から) は、外さない実行と同じ束 (頭の束にも、続きの束にもならない)
            #expect(Array(reattached[4...]) == Array(straight[4...]), "\(name): \(reattached)")
            #expect(reattached[4] != straight[0] && reattached[4] != straight[2], "\(name): 頭か続きから流れた")
        }
    }
}
