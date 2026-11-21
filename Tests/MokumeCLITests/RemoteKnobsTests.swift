// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreImage
import Foundation
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// `run --remote` / `watch --remote` の部品 (#4126): 要求の解釈・面の応答から配る形・書き込みの束ね方・色・QR。
/// 受け口の往復は `RemoteServerTests` が見る。
@Suite("--remote: parts")
struct RemoteKnobsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: - HTTP の要求

    @Test("要求行・クエリ・ヘッダ・本文を読む")
    func parsesARequest() throws {
        let raw = Data(
            "POST /set?t=ab%2Bc&x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\n\r\nbodyEXTRA".utf8)
        guard case .complete(let request, let consumed) = HTTPRequest.parse(raw) else {
            Issue.record("not complete")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/set")
        #expect(request.query == ["t": "ab+c", "x": "1"])
        #expect(request.headers["host"] == "a")
        #expect(request.body == Data("body".utf8))
        #expect(consumed == raw.count - "EXTRA".utf8.count)
    }

    @Test("ヘッダか本文が届ききっていなければ続きを待つ")
    func waitsForTheRest() {
        #expect(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)) == .incomplete)
        #expect(
            HTTPRequest.parse(Data("POST /set HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) == .incomplete)
    }

    @Test("上限を超えた要求と、読めない要求は断る")
    func refusesOversizedAndBroken() {
        let big = Data("POST /set HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        #expect(HTTPRequest.parse(big) == .tooLarge)
        #expect(HTTPRequest.parse(Data(repeating: 65, count: HTTPRequest.limit + 1)) == .tooLarge)
        guard case .invalid = HTTPRequest.parse(Data("HELLO\r\n\r\n".utf8)) else {
            Issue.record("a broken request line was read")
            return
        }
        guard case .invalid = HTTPRequest.parse(Data("POST /set HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        else {
            Issue.record("a chunked body was accepted")
            return
        }
    }

    @Test("合言葉は同じ長さで中身が一致するときだけ通す")
    func comparesTokens() {
        #expect(RemoteServer.sameToken("abc123", "abc123"))
        #expect(!RemoteServer.sameToken("abc124", "abc123"))
        #expect(!RemoteServer.sameToken("abc12", "abc123"))
        #expect(!RemoteServer.sameToken("", ""))
        #expect(RemoteServer.makeToken().count == 32)
        #expect(RemoteServer.makeToken() != RemoteServer.makeToken())
    }

    // MARK: - 面の応答から配る形

    @Test("代表例の応答から、窓と同じ対応表でつまみの種類を決める")
    func buildsKnobsFromTheExampleReport() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Schemas/examples/params-report.json"))
        let payload = try #require(RemoteKnobs.payload(from: data))
        let kinds = Dictionary(uniqueKeysWithValues: payload.knobs.map { ($0.name, $0.kind) })
        #expect(
            kinds == [
                "radius": "slider", "density": "slider", "count": "steppedSlider", "spinning": "toggle",
                "shape": "choice", "ink": "color", "offset": "none",
            ])
        #expect(payload.revision == 7)
        #expect(payload.id == "agent-4711")
        // 代表例の `offset` は範囲を書いていないので、窓と同じくつまみを出さない
        let offset = try #require(payload.knobs.first { $0.name == "offset" })
        #expect(offset.note == KnobKind.Reason.rangeNotDeclared.note)
        let shape = try #require(payload.knobs.first { $0.name == "shape" })
        #expect(shape.choices == ["circle", "square"])
    }

    @Test("範囲の無い数は値だけ出し、窓と同じ理由を添える。読めない 1 件だけを飛ばす")
    func leavesOutWhatHasNoKnob() throws {
        let json = """
            {"schemaVersion":2,"revision":3,"rejected":[{"name":"x","reason":"unknownName"}],
             "clamped":[{"name":"size","requested":9,"value":1}],"discarded":[],
             "params":[{"name":"phase","type":"float","value":0.5},
                       {"name":"broken","type":"nope","value":1},
                       {"name":"size","type":"float","value":1,"min":0,"max":1},
                       {"name":"at","type":"vec3","value":[1,2,3],"min":-5,"max":5}]}
            """
        let payload = try #require(RemoteKnobs.payload(from: Data(json.utf8)))
        #expect(payload.knobs.map(\.name) == ["phase", "size", "at"])
        #expect(payload.knobs[2].kind == "components")
        #expect(payload.knobs[2].count == 3)
        #expect(payload.knobs[2].value == .components([1, 2, 3]))
        #expect(payload.knobs[0].kind == "none")
        #expect(payload.knobs[0].note == KnobKind.Reason.rangeNotDeclared.note)
        #expect(payload.skipped.count == 1)
        #expect(payload.skipped[0].hasPrefix("broken"))
        #expect(payload.clamped == ["size"])
        #expect(payload.rejected == ["x: unknownName"])
    }

    @Test("外枠が読めない応答は捨てる (前の状態を保つのは受け口)")
    func refusesAnUnreadableReport() {
        #expect(RemoteKnobs.payload(from: Data("{\"params\":3}".utf8)) == nil)
        #expect(RemoteKnobs.payload(from: Data("{\"params\":[".utf8)) == nil)
    }

    // MARK: - 書き込みの束ね方

    private func write(_ name: String, _ value: Double) -> NamedParamValue {
        NamedParamValue(name: name, value: .float(value))
    }

    @Test("別の名前の書き込みは 1 つの要求に束ねる (1 件ずつ置くと前の要求が消える)")
    func batchesDifferentNames() {
        var writes = PendingParamWrites()
        writes.record(write("size", 0.5))
        writes.record(write("speed", 3))
        #expect(writes.nextRequest(echoNow: nil, id: "a") == [write("size", 0.5), write("speed", 3)])
        #expect(writes.nextRequest(echoNow: nil, id: "b") == nil)
    }

    @Test("echo で確かめるまで、次の要求にも載せ続ける")
    func keepsUnconfirmedWritesInLaterRequests() {
        var writes = PendingParamWrites()
        writes.record(write("size", 0.5))
        _ = writes.nextRequest(echoNow: nil, id: "a")
        writes.record(write("trails", 1))
        #expect(writes.nextRequest(echoNow: nil, id: "b") == [write("size", 0.5), write("trails", 1)])
        writes.observe(echo: "b")
        #expect(writes.isSettled)
    }

    @Test("前の要求の echo では、その後に動いた値を確かめ済みにしない")
    func anEarlierEchoKeepsNewerValues() {
        var writes = PendingParamWrites()
        writes.record(write("size", 0.5))
        _ = writes.nextRequest(echoNow: nil, id: "a")
        writes.record(write("size", 0.7))
        _ = writes.nextRequest(echoNow: nil, id: "b")
        writes.observe(echo: "a")
        #expect(writes.pending == [write("size", 0.7)])
        #expect(!writes.isSettled)
    }

    @Test("置く前からあった識別子は待ち続け、別の書き手の識別子なら後勝ちで諦める")
    func foreignEchoGivesUp() {
        var writes = PendingParamWrites()
        writes.record(write("size", 0.5))
        _ = writes.nextRequest(echoNow: "window-1", id: "a")
        writes.observe(echo: "window-1")
        #expect(!writes.isSettled)
        writes.observe(echo: "window-2")
        #expect(writes.isSettled)
        #expect(writes.nextRequest(echoNow: "window-2", id: "c") == nil)
    }

    @Test("ページの書き込みを読む: 色は欄の #rrggbb を今の不透明度で、それ以外は面の要求と同じ読み方")
    func readsPageWrites() throws {
        let knobs = [
            RemoteKnobs.Knob(name: "tint", type: "color", kind: "color", value: .color(hex: "#000000", alpha: 0.5))
        ]
        let color = try #require(
            RemoteWrite.parse(Data(##"{"name":"tint","type":"color","value":"#ff0000"}"##.utf8), knobs: knobs))
        guard case .color(let linear) = color.value else {
            Issue.record("not a color: \(color.value)")
            return
        }
        #expect(linear.alpha == 0.5)
        #expect(abs(linear.red - 0.5) < 1e-6)
        #expect(linear.green == 0)
        let number = try #require(RemoteWrite.parse(Data(#"{"name":"size","type":"float","value":0.25}"#.utf8), knobs: []))
        #expect(number == write("size", 0.25))
        #expect(RemoteWrite.parse(Data(#"{"name":"size","type":"float","value":"x"}"#.utf8), knobs: []) == nil)
        #expect(RemoteWrite.parse(Data(##"{"name":"tint","type":"color","value":"#zz0000"}"##.utf8), knobs: knobs) == nil)
    }

    @Test("色の欄と作業空間の色は往復する (乗算を戻して符号化する)")
    func colorsRoundTrip() throws {
        for hex in ["#000000", "#ffffff", "#f27333", "#123456"] {
            let color = try #require(RemoteColor.color(hex: hex, alpha: 0.25))
            #expect(RemoteColor.hex(of: color) == hex)
        }
        #expect(RemoteColor.hex(of: LinearRGBA(premultipliedRed: 0, green: 0, blue: 0, alpha: 0)) == "#000000")
    }

    // MARK: - QR とアドレス

    @Test("端末に描いた QR を読み戻すと、元の URL になる")
    func terminalQRDecodes() throws {
        let url = "http://192.168.1.20:54321/?t=0123456789abcdef0123456789abcdef"
        let code = try #require(QRCode(url))
        let lines = code.terminalLines(colored: false)
        // 半角ブロックを 2 行のモジュールへ戻す
        var rows: [[Bool]] = []
        for line in lines {
            var upper: [Bool] = []
            var lower: [Bool] = []
            for character in line {
                upper.append(character == "█" || character == "▀")
                lower.append(character == "█" || character == "▄")
            }
            rows.append(upper)
            rows.append(lower)
        }
        let image = try #require(QRCode(trimming: rows)?.image(scale: 8))
        let detector = try #require(
            CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [url])
    }

    @Test("色を付けるときは白地に黒を明示する")
    func coloredLinesSetTheirOwnColors() throws {
        let lines = try #require(QRCode("x")).terminalLines(colored: true)
        #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
    }

    @Test("アドレスは en0 を先に、ループバックとリンクローカルを除き、重ねない")
    func ordersAddresses() {
        let entries: [LANAddresses.Entry] = [
            .init(interface: "bridge0", address: "10.0.0.1"),
            .init(interface: "en5", address: "169.254.3.4"),
            .init(interface: "en0", address: "192.168.1.20"),
            .init(interface: "lo0", address: "127.0.0.1"),
            .init(interface: "en1", address: "192.168.1.20"),
        ]
        #expect(LANAddresses.ordered(entries).map(\.address) == ["192.168.1.20", "10.0.0.1"])
    }

    // MARK: - 旗

    @Test("run と watch は --remote を値なしで受ける")
    func flagIsASwitch() throws {
        let base = URL(fileURLWithPath: "/work/here", isDirectory: true)
        let (_, run) = try Invocation.parse(
            ["--remote", "sketch"], adding: RecordOption.options + RemoteOption.options, from: base)
        #expect(RemoteOption.requested(in: run))
        let (_, watch) = try Invocation.parse(["sketch", "--remote"], adding: WatchCommand.options, from: base)
        #expect(RemoteOption.requested(in: watch))
        let (_, without) = try Invocation.parse(["sketch"], adding: WatchCommand.options, from: base)
        #expect(!RemoteOption.requested(in: without))
    }

    @Test("案内: LAN が無ければその旨と localhost を言い、QR は出さない")
    func guidanceWithoutLAN() throws {
        let code = try #require(QRCode("http://localhost:1/?t=a"))
        let lines = RemoteSession.guidance(
            urls: ["http://localhost:1/?t=a"], foundLAN: false, qr: code, colored: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("no network address"))
        let withLAN = RemoteSession.guidance(
            urls: ["http://10.0.0.2:1/?t=a"], foundLAN: true, qr: code, colored: false)
        #expect(withLAN.count == 2 + code.terminalLines(colored: false).count)
    }
}
