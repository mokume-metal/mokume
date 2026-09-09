// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 動かないときに原因へ辿る口 (#509)。GPU は要らない。
///
/// **文を組むところは純関数**にしてあるので、実機の値に依存せずに固定できる。実機でしか
/// 確かめられないのは「読み取りが環境を正しく写しているか」だけで、そちらは人が見る
/// (Issue の `verify: human` はそこに掛かっている)。
@Suite("切り分けの口")
struct DoctorCommandTests {
    static let sound = DoctorCommand.Environment(
        system: "26.1.0", machine: "arm64", canDraw: true,
        resources: URL(fileURLWithPath: "/opt/tool/mokume_MokumeCore.bundle", isDirectory: true),
        toolchain: "Apple Swift version 6.3.3")

    static func state(_ place: URL) -> DoctorCommand.State {
        DoctorCommand.State(place: place, hasPackage: true, buildDirectory: place.appendingPathComponent(".build"), lastBuild: nil)
    }

    @Test("環境の前提は、読み取った値から組む")
    func theEnvironmentSectionComesFromWhatWasRead() {
        let lines = DoctorCommand.environmentLines(Self.sound).joined(separator: "\n")
        #expect(lines.contains("26.1.0"))
        #expect(lines.contains("meets the 26.0 floor"))
        #expect(lines.contains("arm64"))
        #expect(lines.contains("Graphics: available"))
        #expect(lines.contains("Apple Swift version 6.3.3"))
    }

    /// **`canDraw` とは別の軸。** GPU が使えても、資源が配布物に入っていなければ描き
    /// 始められない — v0.6.0 はまさにその形で `watch` が起動しなかった
    /// ([#1054](https://github.com/mokume-metal/mokume/issues/1054))。
    ///
    /// **在処まで出す。** 実行ファイルの隣から読めているのか、組み上げた機械の作業用
    /// ディレクトリから読めているのかが、配った形が成立しているかを決める
    /// ([#1059](https://github.com/mokume-metal/mokume/issues/1059))。
    @Test("同梱の資源は、読めるかと在処の両方を名乗る")
    func theBundledResourcesAreNamedWithTheirLocation() {
        let lines = DoctorCommand.environmentLines(Self.sound).joined(separator: "\n")
        #expect(lines.contains("Bundled resources: readable"))
        #expect(lines.contains("/opt/tool/mokume_MokumeCore.bundle"))

        var stripped = Self.sound
        stripped.resources = nil
        let missing = DoctorCommand.environmentLines(stripped).joined(separator: "\n")
        #expect(missing.contains("Bundled resources: not readable"))
        // GPU の判定は別の軸なので、資源が欠けても「使える」のまま
        #expect(missing.contains("Graphics: available"))
    }

    /// **足りないほうも名指しする。** 前提を満たしていない人は、区画の話を読んでも直せない。
    @Test("下限に足りない版は、足りないと言う")
    func anOldSystemIsNamed() {
        var old = Self.sound
        old.system = "25.9.0"
        #expect(DoctorCommand.environmentLines(old).joined().contains("below the floor"))

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
        #expect(lines.contains("Graphics: \(DoctorCommand.unknown)"))
        #expect(lines.contains("Toolchain: \(DoctorCommand.unknown)"))
    }

    /// 「区画が無い」と「`watch` が死んでいる」を分ける決め手。
    @Test("最後の作り直しは、まだ無いことも言う")
    func theLastBuildIsNamedEvenWhenAbsent() {
        let place = URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
        #expect(DoctorCommand.stateLines(Self.state(place)).joined().contains("none yet"))

        var built = Self.state(place)
        built.lastBuild = DoctorCommand.LastBuild(ok: false, at: Date(timeIntervalSince1970: 0))
        #expect(DoctorCommand.stateLines(built).joined().contains("failed at"))

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
            environment: Self.sound,
            state: DoctorCommand.probeState(in: place, facetBase: place),
            base: place, given: false)
        #expect(text.contains("Observation facet"))
        #expect(text.contains("Input facet"))
        #expect(text.contains("(absent)"))
        // 割れているときの読み方も同じ出力に居ること (前提と区画を分けるための片割れ)
        #expect(text.contains("looking at different facets"))
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

    /// **共有を既定にすると `rm -rf .build` では消えないものが生まれる。** だから
    /// 在処を言える口が要る (掃除の口は足さない — 消すのは `rm -rf` に任せる)。
    ///
    /// **合計 1 行では足りない。** 版の出方が速いので、どの部屋が何MBで、どれをもう誰も
    /// 使っていないかを名乗らないと「どれを消せばよいか」に答えられない
    /// ([#1073](https://github.com/mokume-metal/mokume/issues/1073))。
    @Test("共有の置き場は、部屋ごとの大きさと使われ方を名乗る")
    func theSharedStoreIsNamedRoomByRoom() {
        let root = URL(fileURLWithPath: "/store", isDirectory: true)
        let lines = DoctorCommand.sharedStoreLines(
            DoctorCommand.SharedStore(
                root: root,
                rooms: [
                    Self.room("swiftlang-6.3.3.1.3/0.7.1", mb: 414, .used(2)),
                    Self.room("swiftlang-6.3.3.1.3/0.6.0", mb: 414, .unused(recorded: 1)),
                ],
                resolve: Self.room(BuildDirectory.resolveSegment, mb: 200, .shared),
                bytes: 1028 * 1_048_576))
        let text = lines.joined(separator: "\n")
        #expect(lines[0].contains("/store"))
        #expect(lines[0].contains("2 keys"))
        #expect(lines[0].contains("1028MB"))
        // 部屋ごとの大きさ — これが無いと「どれを消せばよいか」に答えられない
        #expect(text.contains("swiftlang-6.3.3.1.3/0.7.1: 414MB"))
        #expect(text.contains("swiftlang-6.3.3.1.3/0.6.0: 414MB"))
        // もう誰も使っていない部屋が、そう名乗る
        #expect(text.contains("none of them here"))
        // 使われている部屋を「要らない」と読める文にしない
        #expect(text.contains("2 sketches use it"))
        // **合計と内訳の差が説明されている。** 解決専用の部屋 (実測 200MB) が内訳に
        // 現れないと、合計と足し合わない内訳になり、内訳そのものが信用できない
        #expect(text.contains("\(BuildDirectory.resolveSegment): 200MB"))
        #expect(text.contains("resolving dependencies"))

        // まだ 1 つも無いときも在処は言う (どこを見ればよいか分かる形にする)
        let empty = DoctorCommand.sharedStoreLines(
            DoctorCommand.SharedStore(root: root, rooms: [], bytes: 0))
        #expect(empty.count == 1)
        #expect(empty[0].contains("/store"))
        // **数え切れなかったら数を言わない** (規律 3)
        let blind = DoctorCommand.sharedStoreLines(
            DoctorCommand.SharedStore(
                root: root,
                rooms: [
                    DoctorCommand.Room(
                        key: "swiftlang-6.3.3.1.3/0.7.1", bytes: nil, standing: .unrecorded)
                ], bytes: nil))
        #expect(blind.joined(separator: "\n").contains(DoctorCommand.unknown))
        #expect(DoctorCommand.sharedStoreLines(nil).joined().contains(DoctorCommand.unknown))
    }

    /// 部屋の使われ方は、`owners/` に載っている持ち主が実在するかで決まる (#1073 の条件 2)。
    ///
    /// **読めない記録を「誰も使っていない」へ倒さない。** 倒すと人が現役の部屋を消す —
    /// 席を押さえる側が読めない記録を「別人のもの」へ倒すのと同じ向きである (規律 3)。
    @Test("使われ方は、記録と持ち主の実在から決まる")
    func theStandingComesFromTheOwnerRecords() {
        let alive = "/sketches/alive"
        let gone = "/sketches/gone"
        let exists: (String) -> Bool = { $0 == alive }

        #expect(DoctorCommand.standing(owners: [alive, gone], exists: exists) == .used(1))
        #expect(DoctorCommand.standing(owners: [gone], exists: exists) == .unused(recorded: 1))
        #expect(DoctorCommand.standing(owners: [], exists: exists) == .unrecorded)
        // 読めない記録・書きかけの記録があるときは、実在 0 でも断定しない
        #expect(
            DoctorCommand.standing(owners: [gone, nil], exists: exists)
                == .unreadable(recorded: 1))
        #expect(
            DoctorCommand.standing(owners: [gone, "  \n"], exists: exists)
                == .unreadable(recorded: 1))
        // ただし 1 つでも実在すれば、使われていることは動かない
        #expect(DoctorCommand.standing(owners: [alive, nil], exists: exists) == .used(1))

        // **読めた記録が 1 件も無いなら、実在の数を言わない** (「実在 0」だけが残ると、
        // 数えた末に 0 だったのか、そもそも数えられなかったのかが読めない)
        #expect(
            DoctorCommand.standingText(.unreadable(recorded: 0))
                == "owner records unreadable (\(DoctorCommand.unknown))")
        #expect(
            DoctorCommand.standingText(.unreadable(recorded: 2))
                .contains("none of them here"))
    }

    /// 置き場を読むところ。**記録の在処は席を押さえる側と同じ 1 本から出す** ので、
    /// この検査も綴りを写さず `BuildDirectory.claim` で記録を置く (ADR-0037 決定 5)。
    @Test("置き場を読むと、部屋ごとに大きさと持ち主の生死が付く")
    func roomsAreReadFromTheStore() throws {
        let root = try Self.emptyDirectory()
        let sketch = try Self.emptyDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sketch)
        }
        let live = root.appendingPathComponent("swiftlang-6.3.3.1.3/0.7.1", isDirectory: true)
        let dead = root.appendingPathComponent("swiftlang-6.3.3.1.3/0.6.0", isDirectory: true)
        // 実在するスケッチが持ち主の部屋と、消えたスケッチが持ち主の部屋
        #expect(BuildDirectory.claim(["demo"], for: sketch, in: live) == .free)
        #expect(
            BuildDirectory.claim(
                ["demo"], for: root.appendingPathComponent("消えたスケッチ", isDirectory: true),
                in: dead) == .free)
        try Data(repeating: 0x41, count: 4096).write(
            to: live.appendingPathComponent("blob", isDirectory: false))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(BuildDirectory.resolveSegment, isDirectory: true),
            withIntermediateDirectories: true)

        let store = DoctorCommand.sharedStore(at: root)
        #expect(store.keys == 2)
        #expect(
            store.rooms.map(\.key) == [
                "swiftlang-6.3.3.1.3/0.6.0", "swiftlang-6.3.3.1.3/0.7.1",
            ], "部屋は名前の順に並ぶ")
        #expect(store.rooms.first { $0.key.hasSuffix("0.7.1") }?.standing == .used(1))
        #expect(
            store.rooms.first { $0.key.hasSuffix("0.6.0") }?.standing == .unused(recorded: 1),
            "持ち主のスケッチが消えている部屋を、使われていると読んでいる")
        #expect((store.rooms.first { $0.key.hasSuffix("0.7.1") }?.bytes ?? 0) >= 4096)
        // 解決専用の部屋は持ち主を持たないので、使われ方の判定をしない
        #expect(store.resolve?.standing == .shared)
        #expect(store.resolve?.key == BuildDirectory.resolveSegment)
    }

    /// **判定を出すだけで、何も作らず何も消さない** (規律 1 / #1073 の条件 3)。
    ///
    /// 席を押さえる側は消えた持ち主の記録を解放するが (それが正しい)、読むだけの口が
    /// 同じことをすると、**打った人が次に打ったときには判定が変わっている。**
    @Test("置き場を読んでも、部屋も記録も 1 つも変わらない")
    func readingTheStoreChangesNothing() throws {
        let root = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let room = root.appendingPathComponent("swiftlang-6.3.3.1.3/0.6.0", isDirectory: true)
        // 持ち主が消えている記録 = 席を押さえる側なら解放する対象
        #expect(
            BuildDirectory.claim(
                ["demo"], for: root.appendingPathComponent("消えたスケッチ", isDirectory: true),
                in: room) == .free)

        let before = Self.names(under: root)
        _ = DoctorCommand.sharedStore(at: root)
        #expect(
            Self.names(under: root) == before, "切り分けの口が置き場を触っている (規律 1)")
    }

    static func room(_ key: String, mb: Int, _ standing: DoctorCommand.Standing)
        -> DoctorCommand.Room
    {
        DoctorCommand.Room(key: key, bytes: Int64(mb) * 1_048_576, standing: standing)
    }

    /// 置き場の下に在るものの名前 (並べ替えて固定した一覧)。
    static func names(under root: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return ((walker?.allObjects ?? []).compactMap { ($0 as? URL)?.path }).sorted()
    }

    /// 置き場が版ごとの共有へ移っても、切り分けの口は在処を答える。
    /// **在る / 無いだけを名乗ると、共有で建っているスケッチに常に「無い」と言う。**
    @Test("組み上げた跡は、パッケージ直下でなくても在処を名乗る")
    func theBuildDirectoryIsNamedWhereverItIs() {
        var state = Self.state(URL(fileURLWithPath: "/tmp/demo"))
        state.buildDirectory = URL(
            fileURLWithPath: "/store/swiftlang-6.3.3.1.3/0.7.1", isDirectory: true)
        let lines = DoctorCommand.stateLines(state).joined(separator: "\n")
        #expect(lines.contains("/store/swiftlang-6.3.3.1.3/0.7.1"))
        state.buildDirectory = nil
        #expect(DoctorCommand.stateLines(state).joined().contains("Build directory: none"))
    }

    /// 使い方の誤りで止まると、いちばん要るときに読めない。
    @Test("知らない引数は、投げずに無視したと言う")
    func unknownArgumentsAreReportedNotThrown() {
        let text = DoctorCommand.report(
            environment: Self.sound, state: Self.state(URL(fileURLWithPath: "/tmp/demo")),
            base: URL(fileURLWithPath: "/tmp/demo"), given: false, ignored: ["--wat"])
        #expect(text.contains("Ignored unknown arguments"))
        #expect(text.contains("--wat"))
    }

    /// 切り分けの口自身が、切り分けたい「区画の割れ」を再現していた
    /// ([#730](https://github.com/mokume-metal/mokume/issues/730))。`watch` は
    /// `MOKUME_WORK_DIR` を基準に記録を置くのに、`doctor` はスケッチの場所から読んでいた。
    @Test("基準を与えると、doctor は watch が書いた場所から最後の作り直しを読む")
    func theLastBuildIsReadFromTheFacetBase() throws {
        let sketch = try Self.emptyDirectory()
        let work = try Self.emptyDirectory()
        defer {
            try? FileManager.default.removeItem(at: sketch)
            try? FileManager.default.removeItem(at: work)
        }
        // 見張りが書く先へ、見張りと同じ綴りで置く
        let status = BuildReport.statusURL(under: work)
        try FileManager.default.createDirectory(
            at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"ok":true,"status":0,"output":""}"#.utf8).write(to: status)

        // 基準あり — MOKUME_WORK_DIR が解決する基準を渡すと、与えた側から読む
        //
        // **共有の置き場は打った人の手元へ向かせない。** 向かせると、この検査の結果が
        // 機械の状態 (置き場が在るか) で変わる
        let base = WorkDirectory.given(environment: [StartupReads.workDirectory.key: work.path])
        let isolated = [BuildDirectory.environmentKey: work.appendingPathComponent("store").path]
        let given = DoctorCommand.text(
            for: [sketch.path], workDirectory: base, environment: isolated)
        // **行を名指しで見る。** 「まだ無い」は他の行にも出るので、含まれないことを
        // 全文へ問うと、無関係な行が増えた日に落ちる
        #expect(
            given.contains("Last build:") && !given.contains("Last build: none yet"),
            "基準を与えた環境で、doctor が watch の書いた記録を読めていない")
        #expect(given.contains("succeeded at"))

        // 基準なし — スケッチの場所から読む (いままでどおり。あちらには何も無い)
        let plain = DoctorCommand.text(
            for: [sketch.path], workDirectory: nil, environment: isolated)
        #expect(plain.contains("Last build: none yet"))
    }

    static func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
