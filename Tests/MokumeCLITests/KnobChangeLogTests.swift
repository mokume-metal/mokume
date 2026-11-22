// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// つまみの変化を時刻付きの 1 行に畳む (#4130)。応答の差分から、書き手・畳み方・綴りを見る。
@Suite("--remote / watch: knob change log")
struct KnobChangeLogTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)
    private static let utc = TimeZone(identifier: "UTC")!

    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// 最初の応答 (誰も書いていない) を読ませたログ。
    private static func primed(_ values: [String: ParamValue]) -> KnobChangeLog {
        var log = KnobChangeLog()
        log.observe(echo: nil, values: values, at: at(0))
        return log
    }

    @Test("スマホで引いて離すと、最初と最後の値で 1 行に畳む")
    func foldsADragIntoOneLine() {
        var log = Self.primed(["radius": .float(0.40)])
        log.observe(echo: "remote-a", values: ["radius": .float(0.45)], at: Self.at(1.0))
        log.observe(echo: "remote-b", values: ["radius": .float(0.50)], at: Self.at(1.1))
        log.observe(echo: "remote-c", values: ["radius": .float(0.55)], at: Self.at(1.2))
        #expect(log.flush(at: Self.at(1.6)).isEmpty, "still moving (0.4 s since the last change)")
        let changes = log.flush(at: Self.at(1.7))
        #expect(
            changes == [.init(name: "radius", from: .float(0.40), to: .float(0.55), at: Self.at(1.2), writer: "phone")])
        #expect(log.flush(at: Self.at(5)).isEmpty, "a folded change is written once")
    }

    @Test("窓・名乗らない書き手を言い分ける")
    func namesTheWriter() {
        var log = Self.primed(["a": .int(1), "b": .bool(false)])
        log.observe(echo: "window-x", values: ["a": .int(2), "b": .bool(false)], at: Self.at(1))
        log.observe(echo: "1a2b3c4d", values: ["a": .int(2), "b": .bool(true)], at: Self.at(1))
        let writers = log.flush(at: Self.at(2)).map { "\($0.name):\($0.writer)" }
        #expect(writers == ["a:window", "b:other"])
    }

    @Test("echo が変わらない値の変化 (スケッチ自身の代入・子の入れ替わり) は書かない")
    func ignoresChangesWithoutANewEcho() {
        var log = Self.primed(["t": .float(0)])
        log.observe(echo: nil, values: ["t": .float(1)], at: Self.at(1))
        log.observe(echo: "remote-a", values: ["t": .float(1)], at: Self.at(2))
        log.observe(echo: "remote-a", values: ["t": .float(2)], at: Self.at(3))
        #expect(log.flush(at: Self.at(10)).isEmpty)
    }

    @Test("元の値へ戻したなら書かない")
    func dropsARoundTrip() {
        var log = Self.primed(["n": .int(3)])
        log.observe(echo: "window-a", values: ["n": .int(4)], at: Self.at(1))
        log.observe(echo: "window-b", values: ["n": .int(3)], at: Self.at(1.1))
        #expect(log.flush(at: Self.at(2)).isEmpty)
    }

    @Test("新しく現れた名前・型の変わった名前・消えた名前は書かない")
    func ignoresDeclarationChanges() {
        var log = Self.primed(["kept": .int(1), "gone": .int(1), "retyped": .int(1)])
        log.observe(
            echo: "remote-a", values: ["kept": .int(1), "new": .int(5), "retyped": .float(1.5)], at: Self.at(1))
        #expect(log.flush(at: Self.at(2)).isEmpty)
    }

    @Test("終わるときは動いている途中の変化も待たずに書く")
    func flushesEverythingWhenStopping() {
        var log = Self.primed(["x": .float(0)])
        log.observe(echo: "remote-a", values: ["x": .float(1)], at: Self.at(1))
        #expect(log.flush(at: Self.at(1.1)).isEmpty)
        #expect(log.flush(at: Self.at(1.1), all: true).map(\.name) == ["x"])
    }

    @Test("行の綴り: 時刻・揃えた名前・窓と同じ値の綴り・書き手。端末でなければ制御文字を出さない")
    func spellsTheLine() {
        let change = KnobChangeLog.Change(
            name: "radius", from: .float(0.4), to: .float(0.55), at: Date(timeIntervalSince1970: 3_784.5125),
            writer: "phone")
        let plain = KnobChangeLog.line(change, nameWidth: 8, colored: false, zone: Self.utc)
        #expect(plain == "01:03:04.512  radius    0.40 → 0.55  (phone)")
        let colored = KnobChangeLog.line(change, nameWidth: 8, colored: true, zone: Self.utc)
        #expect(colored.contains("\u{1B}["))
        #expect(colored.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) == plain)
    }

    @Test("名前の欄は見たことのある最も長い名前に揃える")
    func widensTheNameColumn() {
        let log = Self.primed(["a": .int(0), "longerName": .int(0)])
        #expect(log.nameWidth == "longerName".count)
    }

    @Test("見張りは面の応答を読んで行を書き、止めるときに残りを書く")
    func watcherReadsTheReport() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("knob-log-\(UUID().uuidString)/.mokume/params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet.deletingLastPathComponent().deletingLastPathComponent()) }
        let report = WorkDirectory.reportURL(under: facet)
        func place(id: String?, size: Double, modified: TimeInterval) throws {
            let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
            try Data(#"{\#(idField)"params":[{"name":"size","type":"float","value":\#(size)}]}"#.utf8)
                .write(to: report)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: report.path)
        }
        let lines = Lines()
        let watcher = KnobChangeWatcher(facet: facet, colored: false) { lines.append($0) }
        try place(id: nil, size: 10, modified: 1)
        watcher.tick(at: Self.at(0))
        try place(id: "window-a", size: 20, modified: 2)
        watcher.tick(at: Self.at(1))
        #expect(lines.all.isEmpty, "still inside the settle window")
        watcher.tick(at: Self.at(2))
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.hasSuffix("size  10.00 → 20.00  (window)") == true)
        try place(id: "remote-b", size: 30, modified: 3)
        watcher.tick(at: Self.at(3))
        watcher.start()
        watcher.stop()
        #expect(lines.all.count == 2)
        #expect(lines.all.last?.hasSuffix("size  20.00 → 30.00  (phone)") == true)
    }

    private nonisolated final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
}
