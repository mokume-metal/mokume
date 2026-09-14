// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// JSON を区画へ置く口 ([#989](https://github.com/mokume-metal/mokume/issues/989))。GPU は要らない。
///
/// **入口は 2 つで、名前が失敗の扱いを決める。** かつては同じ処理が 8 箇所にあり、
/// `try?` で捨てる・`warn` で名乗る・`throws` で投げるの 3 通りが混ざっていた。
@Suite("JSON を置く口")
struct AtomicFileTests {
    /// **宣言順と辞書順が違う**見本 (宣言は zebra → apple → middle)。
    private struct Sample: Encodable {
        let zebra: Int
        let apple: String
        let middle: Bool
    }

    private let sample = Sample(zebra: 1, apple: "a", middle: true)

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 書かれた JSON に現れる鍵を、現れた順に取る。
    private func keys(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }

    @Test("鍵の並びは辞書順で決まる")
    func spellsKeysInSortedOrder() throws {
        let url = try makeFacet().appendingPathComponent("sample.json")
        try AtomicFile.writeJSON(sample, to: url)

        // 宣言順 (zebra, apple, middle) ではなく辞書順で届く。`.sortedKeys` を付けて
        // いなかった頃は辞書の走査順で、プロセスごとに変わっていた (#854 の実測)
        #expect(keys(in: try String(contentsOf: url, encoding: .utf8)) == ["apple", "middle", "zebra"])
    }

    @Test("置けたら真、置けなければ偽")
    func reportsWhetherItLanded() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("report.json")
        #expect(AtomicFile.publishJSON(sample, to: url, "見本"))

        // 書き込み先を塞ぐ。**捨てたかどうかで続きが変わる呼び手が居る** —
        // 置けたときだけ識別子を控える (RemoteParams)・数を進める (ParamStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        #expect(AtomicFile.publishJSON(sample, to: url, "見本") == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)
    }

    @Test("置けなかったことは、置き場所ごとに 1 度だけ名乗る")
    func namesTheFailureOnlyOnce() throws {
        let facet = try makeFacet()
        let blocked = facet.appendingPathComponent("blocked.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: facet.path)
        }

        #expect(AtomicFile.hasWarned(about: blocked) == false)
        _ = AtomicFile.publishJSON(sample, to: blocked, "最初の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("最初の名乗り") == true)

        // 2 度目は黙る。つまみを掴んでいる間は入力のたびにここへ来るので、毎回言うと
        // 標準エラーが流れて他の注意が読めなくなる
        _ = AtomicFile.publishJSON(sample, to: blocked, "二度目の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("二度目") == false)

        // 鍵は置き場所。別の面の失敗は、別に名乗る
        let other = facet.appendingPathComponent("other.json")
        #expect(AtomicFile.hasWarned(about: other) == false)
    }

    /// 区画に残っている一時ファイルの名前。
    private func temporaries(in facet: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: facet.path).filter { $0.hasSuffix(".tmp") }
    }

    /// **2 つのプロセスが同じ名前へ同時に書く並びを、1 プロセスで決定的に作る。**
    ///
    /// 作る → 相手が作る → 相手が置く → 自分が置く。`watch` は切り替えの瞬間だけ 2 世代を
    /// 重ねるので、両方が同じ区画へ応答や絵を置くとこの並びになる。一時ファイルの名前が
    /// 固定だった頃は相手が自分の一時ファイルを上書きして持ち去り、自分の置く段が
    /// 「一時ファイルが無い」で投げていた (手元の 2 プロセスの実測で書き込みの 4 割強・
    /// [#1198](https://github.com/mokume-metal/mokume/issues/1198))。
    @Test("書いている途中に同じ名前への別の書き込みが割り込んでも、両方が置ける")
    func survivesAnotherWriterOnTheSameName() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("report.json")

        try AtomicFile.write(to: url) { temporary in
            try Data("mine".utf8).write(to: temporary)
            try AtomicFile.write(Data("theirs".utf8), to: url)
        }

        // 後から置いたほうが残る。読み手から見えるのは、どちらかの中身だけである
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
        #expect(try temporaries(in: facet).isEmpty)
    }

    /// **置けなかった書き込みの後始末は、書いた側がする。** 名前を書き込みごとに変えると、
    /// 誰も上書きしないので残った分がそのまま溜まる。
    @Test("置けなかった一時ファイルは残さない")
    func removesItsTemporaryWhenItFails() throws {
        struct Interrupted: Error {}
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")

        #expect(throws: Interrupted.self) {
            try AtomicFile.write(to: url) { temporary in
                try Data("half".utf8).write(to: temporary)
                throw Interrupted()
            }
        }
        #expect(try temporaries(in: facet).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// 走らせた子のプロセス。`waitUntilExit` まで待てば、その番号にはもう誰も居ない。
    private func launch(_ path: String, _ arguments: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// **書いている途中に落とされた書き手の分は、次に同じ名前を書くプロセスが片付ける。**
    ///
    /// スケッチは `SIGTERM` で即座に終わるので、見張りの差し替えのたびに一時ファイルが
    /// 残りうる。名前を書き込みごとに変えた以上、片付ける者が居ないと溜まり続ける。
    /// **重なっている別の世代が書いている途中のものは消さない** — 消すと、その世代の
    /// 置く段が「一時ファイルが無い」で投げる (#1198 の症状そのもの)。
    @Test("居なくなった書き手の一時ファイルは片付け、生きている書き手のものは残す")
    func sweepsTemporariesOfWritersThatAreGone() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("frame-000.png")

        let gone = try launch("/usr/bin/true")
        gone.waitUntilExit()
        let alive = try launch("/bin/sleep", ["30"])
        defer { alive.terminate() }

        let abandoned = AtomicFile.temporaryURL(for: url, writer: gone.processIdentifier, sequence: 7)
        let inFlight = AtomicFile.temporaryURL(for: url, writer: alive.processIdentifier, sequence: 3)
        // 別の名前の一時ファイルは、この名前を書いても触れない
        let otherName = AtomicFile.temporaryURL(
            for: facet.appendingPathComponent("frame-001.png"), writer: gone.processIdentifier,
            sequence: 8)
        for leftover in [abandoned, inFlight, otherName] {
            try Data("half".utf8).write(to: leftover)
        }

        try AtomicFile.write(Data("frame".utf8), to: url)

        #expect(try temporaries(in: facet).sorted()
            == [inFlight.lastPathComponent, otherName.lastPathComponent].sorted())
    }

    @Test("一時ファイルの名前から書き手を引くのは、その置き場所の形をしたものだけ")
    func readsTheWriterOnlyFromItsOwnTemporaries() {
        let url = URL(fileURLWithPath: "/facet/report.json")
        let own = AtomicFile.temporaryURL(for: url, writer: 4242, sequence: 1).lastPathComponent
        #expect(AtomicFile.writer(ofTemporary: own, for: url) == 4242)

        // 固定名だった頃の名前・別の置き場所・形の崩れたものは、誰のものとも言えない
        for name in [
            ".report.json.tmp", ".report.json.x.4242-1.tmp", ".report.json.0-1.tmp",
            ".report.json.4242-.tmp", ".report.json.4242.tmp", ".other.json.4242-1.tmp",
        ] {
            #expect(AtomicFile.writer(ofTemporary: name, for: url) == nil, "\(name)")
        }
    }
}
