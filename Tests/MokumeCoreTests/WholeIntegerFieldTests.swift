// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 外から届く JSON の整数の欄が、桁の多い端数つきの数を端数を捨てた整数として読まないこと
/// ([#4015](https://github.com/mokume-metal/mokume/issues/4015))。
///
/// `JSONDecoder` の整数への読みは `2.5` を断るのに、`1.00000000000000000000001` を断らずに 1 と読む。
/// 欄ごとの約束 (断る・`ignored` に数える・「印が無い」と読む) は変えず、桁の多い端数つきの数を `2.5` と
/// 同じ扱いにそろえる。数は JSON の文字から読ませる (`Double` を経ると端数が先に消える)。
@Suite("外から届く整数の欄の、桁の多い端数")
struct WholeIntegerFieldTests {
    nonisolated static let fields = [
        "button", "button (input-request)", "code", "code (input-request)", "clickCount",
        "clickCount (input-request)", "serial", "serial (input-request)", "int の値",
        "目録の schemaVersion", "目録の ids", "目録の width", "目録の height", "目録の pid",
        "一覧の schemaVersion", "一覧の pid", "一覧の startedAt", "生死の pid", "生死の startedAt",
        "時計の版", "時計の版 (Snapshot)", "時計の writer",
    ]

    /// `Int32`・`UInt32` で読む欄 (`4294967296` を範囲の外として断る)。
    nonisolated static let narrowFields: Set = ["目録の ids", "目録の pid", "一覧の pid", "生死の pid", "時計の writer"]

    /// 1 のほかを版の照合で断る欄 (`4294967296` の読みを比べようがない)。
    nonisolated static let versionFields: Set = ["目録の schemaVersion", "時計の版"]

    /// 整数の欄が読む `Int`・`Int32`・`UInt32` のどれにも収まる、どの欄でも読める値 1 の、端数を持つ近傍。
    /// どれも `JSONDecoder` の整数への読みが、断らずに端数を捨てていた綴り (直す前の実測は #4015 の PR)。
    nonisolated static let longFractions = [
        "1.00000000000000000000001", "12345678901234567.5", "0.99999999999999999999999",
        "9007199254740993.5", "-0.00000000000000000000001",
    ]

    /// 欄 `field` に綴り `spelling` を書いた JSON を読ませ、読んだ結果を文字で返す (読めなければ `refused`)。
    private func read(_ field: String, _ spelling: String) -> String {
        switch field {
        case "button": rawEvent(#"{"type":"mouseDown","x":1,"y":2,"button":\#(spelling)}"#)
        case "button (input-request)": requested(#"{"type":"mouseUp","x":1,"y":2,"button":\#(spelling)}"#)
        case "code": rawEvent(#"{"type":"keyDown","code":\#(spelling),"characters":"a"}"#)
        case "code (input-request)": requested(#"{"type":"keyUp","code":\#(spelling)}"#)
        case "clickCount": rawEvent(#"{"type":"mouseDown","x":1,"y":2,"clickCount":\#(spelling)}"#)
        case "clickCount (input-request)":
            requested(#"{"type":"mouseDown","x":1,"y":2,"clickCount":\#(spelling)}"#)
        case "serial": rawEvent(#"{"type":"fileSelected","paths":["/tmp/a.csv"],"serial":\#(spelling)}"#)
        case "serial (input-request)": requested(#"{"type":"fileSelected","paths":[],"serial":\#(spelling)}"#)
        case "int の値":
            describe {
                try JSONDecoder().decode(ParamValue.self, from: Data(#"{"type":"int","value":\#(spelling)}"#.utf8))
            }
        case "目録の schemaVersion": manifest(version: spelling)
        case "目録の ids": manifest(ids: spelling)
        case "目録の width": manifest(width: spelling)
        case "目録の height": manifest(height: spelling)
        case "目録の pid": manifest(pid: spelling)
        case "一覧の schemaVersion": listed(version: spelling)
        case "一覧の pid": listed(pid: spelling)
        case "一覧の startedAt": listed(startedAt: spelling)
        case "生死の pid": swept(pid: spelling)
        case "生死の startedAt": swept(startedAt: spelling)
        case "時計の版": handedOver(version: spelling)
        case "時計の版 (Snapshot)":
            describe {
                try JSONDecoder().decode(ClockHandover.Snapshot.self, from: Data(Self.snapshot(version: spelling).utf8))
                    .version
            }
        case "時計の writer": handedOver(writer: spelling)
        default: "unknown field"
        }
    }

    /// 名乗った送り手の目録 (`frame-listing`) の 1 件として読ませる。
    private func listed(version: String = "1", pid: String = "7", startedAt: String = "5") -> String {
        describe {
            let json = #"{"schemaVersion":\#(version),"sketch":"s","window":"main","identity":"/a","title":"t","pid":\#(pid),"startedAt":\#(startedAt),"serviceName":"n"}"#
            let entry = try JSONDecoder().decode(FrameListing.Entry.self, from: Data(json.utf8))
            return "v\(entry.schemaVersion) pid=\(entry.pid) at=\(entry.startedAt)"
        }
    }

    /// 死んだ項目の掃除 (``FrameListing/sweep(in:isAlive:startTime:)``) に読ませる。読めない項目は飛ばす。
    /// pid のプロセスは生きていて、起動の時刻は 5 と答える (時刻が違えば使い回しとして消す)。
    private func swept(pid: String = "7", startedAt: String = "5") -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whole-integer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #"{"pid":\#(pid),"startedAt":\#(startedAt)}"#.write(
                to: directory.appendingPathComponent("n.json"), atomically: true, encoding: .utf8)
        } catch { return "could not place: \(error)" }
        var asked: [pid_t] = []
        let removed = FrameListing.sweep(
            in: directory, isAlive: { asked.append($0); return true }, startTime: { _ in 5 })
        return asked.isEmpty ? "skipped" : "pid=\(asked) removed=\(removed)"
    }

    nonisolated private static func snapshot(version: String = "1", writer: String = "7") -> String {
        #"{"version":\#(version),"seconds":1,"isHeld":false,"isStill":false,"at":1,"writer":\#(writer),"generation":1}"#
    }

    /// 前の世代が書いた時計 (``ClockHandover/read(path:)``) として読ませる。読めなければ使わない。
    private func handedOver(version: String = "1", writer: String = "7") -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whole-integer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Self.snapshot(version: version, writer: writer).write(to: url, atomically: true, encoding: .utf8)
        } catch { return "could not place: \(error)" }
        switch ClockHandover.read(path: url.path) {
        case .absent: return "absent"
        case .unusable: return "unusable"
        case .found(let snapshot): return "v\(snapshot.version) writer=\(snapshot.writer)"
        }
    }

    private func describe<Value>(_ body: () throws -> Value) -> String {
        do { return String(describing: try body()) } catch { return "refused" }
    }

    private func rawEvent(_ json: String) -> String {
        describe { try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8)).event as Any }
    }

    /// 外から送る要求 (`input-request`) の 1 件として読ませる。読めない 1 件は `ignored` に数えられる。
    private func requested(_ event: String) -> String {
        describe {
            let json = #"{"id":"a","events":[\#(event)]}"#
            let request = try JSONDecoder().decode(InputRequest.self, from: Data(json.utf8))
            return request.events.first?.event.map { "\($0)" } ?? "ignored"
        }
    }

    private func manifest(
        version: String = "1", ids: String = "1", width: String = "4", height: String = "3",
        pid: String = "7"
    ) -> String {
        describe {
            let json = #"{"schemaVersion":\#(version),"ids":[\#(ids)],"width":\#(width),"height":\#(height),"pid":\#(pid)}"#
            let manifest = try JSONDecoder().decode(SharedFrameSurface.Manifest.self, from: Data(json.utf8))
            return "ids=\(manifest.ids) \(manifest.width)x\(manifest.height) pid=\(manifest.pid.map(String.init) ?? "nil")"
        }
    }

    @Test("桁の多い端数つきの数は、2.5 と同じ扱い (断る・ignored に数える・印が無いと読む)", arguments: fields)
    func readsALongFractionLikeTwoPointFive(field: String) {
        let fraction = read(field, "2.5")
        #expect(fraction != read(field, "1"), "2.5 を 1 と同じに読んだ: \(fraction)")
        for spelling in Self.longFractions {
            #expect(read(field, spelling) == fraction, "\(spelling)")
        }
    }

    /// 整数の綴りと範囲の外の整数の読みは、直す前と同じ (直す前の実測は #4015 の PR)。
    @Test("整数の綴りはその値、範囲の外の整数は今までどおり", arguments: fields)
    func keepsWholeSpellingsAsBefore(field: String) {
        #expect(read(field, "1") != read(field, "2.5"))
        for spelling in ["1.0", "1e0", "10e-1", "1.00000000000000000000000"] {
            #expect(read(field, spelling) == read(field, "1"), "\(spelling)")
        }
        #expect(read(field, "1E+3") == read(field, "1000"))
        #expect(read(field, "-0") == read(field, "0"))
        // `Decimal` の仮数 (38 桁) を越える綴りは、読み手に届く前に 1 へ丸まる (WholeDecimal の限界)
        #expect(read(field, "1.00000000000000000000000000000000000000000001") == read(field, "1"))
        // どの欄の型にも収まらない整数は、直す前から 2.5 と同じに断る
        for spelling in ["1e19", "9223372036854775808", "-9223372036854775809"] {
            #expect(read(field, spelling) == read(field, "2.5"), "\(spelling)")
        }
        // `Int` には収まり `Int32`・`UInt32` に収まらない整数は、欄の型のとおり (版は 1 のほかを断る欄なので見ない)
        guard !Self.versionFields.contains(field) else { return }
        let narrow = Self.narrowFields.contains(field)
        #expect((read(field, "4294967296") == read(field, "2.5")) == narrow, "\(read(field, "4294967296"))")
    }

    /// 包んだ欄 (``WholeNumber``) は、書くときは包まずに数のまま書く。書き出す JSON の形と、読み戻した値の
    /// 等しさは変わらない (`frame-listing` の Schema と読み手の約束)。
    @Test("包んだ欄も、数のまま書いて同じ値に読み戻す")
    func wrappedFieldsAreWrittenAsPlainNumbers() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let entry = FrameListing.Entry(
            sketch: "s", identity: "/a", title: "t", pid: 7, startedAt: 1_700_000_000_000_000, serviceName: "n")
        let listed = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(
            listed
                == #"{"identity":"\/a","pid":7,"schemaVersion":1,"serviceName":"n","sketch":"s","startedAt":1700000000000000,"title":"t","window":"main"}"#,
            "\(listed)")
        #expect(try JSONDecoder().decode(FrameListing.Entry.self, from: Data(listed.utf8)) == entry)

        let snapshot = ClockHandover.Snapshot(
            seconds: 1.5, isHeld: false, isStill: false, rate: nil, at: 2, writer: 42, generation: 3)
        let written = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(written.contains(#""version":1"#) && written.contains(#""writer":42"#), "\(written)")
        #expect(try JSONDecoder().decode(ClockHandover.Snapshot.self, from: Data(written.utf8)) == snapshot)
    }
}
