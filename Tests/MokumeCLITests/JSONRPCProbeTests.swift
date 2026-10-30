// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import Testing

@testable import MokumeCLI

/// **窓口の入口 (`JSONRPC.parse`) に、壊した行を当てる** ([#3220]・#3207 の提案 5)。GPU を使わない。
///
/// 窓口は、外のエージェントが送ってくる 1 行ずつの JSON を最初に読む。壊れた行は、落ちず・止まらず、
/// 呼び出しとして読むか、JSON-RPC 2.0 の誤りで断るか、応答として読み飛ばすかのどれかで答える。断りの
/// 1 行は、それ自体が 1 行の JSON で、`error.code` (整数)・`error.message` と、読めるなら `id` を持つ。
/// 見本は本物の呼び出しの形で、`MokumeCoreTests` の `LoaderProbeTests` と同じ生成器 (``ProbeBytes``) で壊す。
///
/// [#3220]: https://github.com/mokume-metal/mokume/issues/3220
@Suite("窓口の入口は、壊した行にも落ちず止まらず、呼び出しか名乗りつきの断りか読み飛ばしで答える")
nonisolated struct JSONRPCProbeTests {
    static let samples: [[UInt8]] = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}"#,
        #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"observe","arguments":{"count":3,"ratio":0.5}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#,
    ].map { Array($0.utf8) }

    /// 断りの 1 行が、JSON-RPC 2.0 の誤りの形か。外れていればその理由。
    static func shapeOfRefusal(_ reply: String) -> String? {
        if reply.contains("\n") { return "断りが 1 行でない" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            return "断りが JSON のオブジェクトでない: \(reply)"
        }
        guard object["jsonrpc"] as? String == "2.0" else { return "断りの jsonrpc が 2.0 でない: \(reply)" }
        guard let error = object["error"] as? [String: Any], error["code"] is Int,
            let message = error["message"] as? String, !message.isEmpty
        else { return "断りが error.code (整数) と error.message を持たない: \(reply)" }
        switch object["id"] {
        case is String, is NSNumber, is NSNull: return nil
        default: return "断りの id が文字・数・null のどれでもない: \(reply)"
        }
    }

    @Test("JSONRPC.parse は、壊れた行にも落ちず止まらず、呼び出し・名乗りつきの断り・応答の読み飛ばしのどれかで答える")
    func parse() {
        let report = Probe.run(
            "parse", suite: "JSONRPCProbeTests", key: "JSONRPC.parse",
            axes: ProbeBytes.axes(samples: Self.samples.count), cases: 64, shrinkSteps: 12
        ) { input in
            let bytes = ProbeBytes.mutate(Self.samples, input)
            let named = "JSONRPC.parse \(ProbeBytes.describe(bytes))"
            guard
                let verdict = Guarded.run(
                    "[parse \(input.seedText)] JSONRPC.parse \(ProbeBytes.describe(bytes, limit: 400))", limit: 5,
                    {
                        switch JSONRPC.parse(ProbeBytes.text(bytes)) {
                        case .refused(let reply): return Self.shapeOfRefusal(reply)
                        case .call(let call): return call.method.isEmpty ? "呼び出しの method が空" : nil
                        case .response: return nil
                        }
                    })
            else { return .fail("\(named) が 5 秒で返らない") }
            return verdict.map { .fail("\(named): \($0)") } ?? .pass
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.failure != nil || report.ran >= 64, "見たのは \(report.ran) 件・約束の外 \(report.skipped) 件")
    }
}
