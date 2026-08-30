// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 動かないときに原因へ辿る口 (#509)。GPU は要らない。
///
/// **文を組むところは純関数**にしてあるので、実機の値に依存せずに固定できる。実機でしか
/// 確かめられないのは「読み取りが環境を正しく写しているか」だけで、そちらは人が見る
/// (Issue の `verify: human` はそこに掛かっている)。
@Suite("切り分けの口")
struct DoctorCommandTests {
    static let sound = DoctorCommand.Environment(
        system: "26.1.0", machine: "arm64", canDraw: true, toolchain: "Apple Swift version 6.3.3")

    static func state(_ place: URL) -> DoctorCommand.State {
        DoctorCommand.State(place: place, hasPackage: true, hasBuild: true, lastBuild: nil)
    }

    @Test("環境の前提は、読み取った値から組む")
    func theEnvironmentSectionComesFromWhatWasRead() {
        let lines = DoctorCommand.environmentLines(Self.sound).joined(separator: "\n")
        #expect(lines.contains("26.1.0"))
        #expect(lines.contains("満たしている"))
        #expect(lines.contains("arm64"))
        #expect(lines.contains("使える"))
        #expect(lines.contains("Apple Swift version 6.3.3"))
    }

    /// **足りないほうも名指しする。** 前提を満たしていない人は、区画の話を読んでも直せない。
    @Test("下限に足りない版は、足りないと言う")
    func anOldSystemIsNamed() {
        var old = Self.sound
        old.system = "25.9.0"
        #expect(DoctorCommand.environmentLines(old).joined().contains("足りない"))

        // 文字列の大小で比べると 26.10 が 26.9 より小さくなる
        #expect(DoctorCommand.meetsFloor("26.10", floor: "26.9"))
        #expect(!DoctorCommand.meetsFloor("25.9", floor: "26.0"))
        #expect(DoctorCommand.meetsFloor("26.0", floor: "26.0"))
    }

    /// **断定できないときは断定しない** (ADR-0029 決定 2 の規律 2)。
    @Test("読めなかったものは、判定できずと名乗る")
    func whatCouldNotBeReadSaysSo() {
        var blind = Self.sound
        blind.canDraw = nil
        blind.toolchain = nil
        let lines = DoctorCommand.environmentLines(blind).joined(separator: "\n")
        #expect(lines.contains("描く道具: \(DoctorCommand.unknown)"))
        #expect(lines.contains("道具立て: \(DoctorCommand.unknown)"))
    }

    /// 「区画が無い」と「`watch` が死んでいる」を分ける決め手。
    @Test("最後の作り直しは、まだ無いことも言う")
    func theLastBuildIsNamedEvenWhenAbsent() {
        let place = URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
        #expect(DoctorCommand.stateLines(Self.state(place)).joined().contains("まだ無い"))

        var built = Self.state(place)
        built.lastBuild = DoctorCommand.LastBuild(ok: false, at: Date(timeIntervalSince1970: 0))
        #expect(DoctorCommand.stateLines(built).joined().contains("落ちた"))

        var unreadable = Self.state(place)
        unreadable.lastBuild = DoctorCommand.LastBuild(ok: nil, at: Date(timeIntervalSince1970: 0))
        #expect(DoctorCommand.stateLines(unreadable).joined().contains(DoctorCommand.unknown))
    }

    /// #464 と同じ状況 — 作ったばかりで区画がまだ無い。**出力を読むだけでそこへ到達できる。**
    @Test("区画が無い状況が、出力から読み取れる")
    func missingFacetsAreVisible() throws {
        let place = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: place) }

        let text = DoctorCommand.report(
            environment: Self.sound, state: DoctorCommand.probeState(in: place),
            base: place, given: false)
        #expect(text.contains("観測の区画"))
        #expect(text.contains("入力の区画"))
        #expect(text.contains("(無い)"))
        // 割れているときの読み方も同じ出力に居ること (前提と区画を分けるための片割れ)
        #expect(text.contains("別の区画を見ている"))
    }

    /// **何も直さない** (ADR-0029 決定 2 の規律 1)。打ったら直ってしまうと、直った理由が
    /// 残らない。窓口の側は要求を置くために区画を作るので、ここが同じことをしないのを固定する。
    @Test("打っても、区画は作られない")
    func nothingIsCreated() throws {
        let place = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: place) }

        DoctorCommand.run([place.path])

        #expect(
            !FileManager.default.fileExists(
                atPath: place.appendingPathComponent(".mokume").path),
            "切り分けの口が区画を作っている (打ったら直る = 原因が消える)")
    }

    /// 使い方の誤りで止まると、いちばん要るときに読めない。
    @Test("知らない引数は、投げずに無視したと言う")
    func unknownArgumentsAreReportedNotThrown() {
        let text = DoctorCommand.report(
            environment: Self.sound, state: Self.state(URL(fileURLWithPath: "/tmp/demo")),
            base: URL(fileURLWithPath: "/tmp/demo"), given: false, ignored: ["--wat"])
        #expect(text.contains("無視した"))
        #expect(text.contains("--wat"))
    }

    static func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
