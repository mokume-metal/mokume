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

    // MARK: - 見ている場所が無い (#2314)

    /// 共有の置き場を打った人の手元へ向かせない環境 (結果を機械の状態で変えない)。
    private static func isolated() -> [String: String] {
        [
            BuildDirectory.environmentKey: FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-doctor-store-\(UUID().uuidString)").path
        ]
    }

    /// **場所が無いことを、道具立てのせいにしない** (規律 3)。道具立ては見ている場所で
    /// `swift` を起こして読むので、場所が無いと起きない。それを「could not launch swift」と
    /// 言うと、入っている `swift` を疑わせ、打ち間違えた場所からは遠ざける。
    @Test("在らない場所を渡すと、場所が無いと名乗り、swift を起こせなかったとは言わない")
    func aMissingPlaceIsNamedWithoutBlamingTheToolchain() {
        let missing = "/nonexistent-\(UUID().uuidString)/xyz"
        let text = DoctorCommand.text(for: [missing], workDirectory: nil, environment: Self.isolated())
        #expect(text.contains("Place: \(missing) — nothing is there"))
        #expect(!text.contains("could not launch swift"))
        #expect(text.contains("Toolchain: \(DoctorCommand.unknown) — not asked"))
    }

    @Test("ファイルを渡すと、ディレクトリでないと名乗り、swift を起こせなかったとは言わない")
    func aFileAsThePlaceIsNamed() throws {
        let place = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: place) }
        let file = place.appendingPathComponent("Package.swift")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let text = DoctorCommand.text(
            for: [file.path], workDirectory: nil, environment: Self.isolated())
        #expect(text.contains("— not a directory"))
        #expect(!text.contains("could not launch swift"))
    }

    /// **入れない場所を「無い」と言わない** (#2314 の反証)。`fileExists` は入れない場所も
    /// 宛先の無い symlink も false にするので、それだけで「nothing is there」と言うと、在る
    /// 場所を探させる。
    @Test(
        "入れない場所・宛先の無い symlink を渡すと、無いとは言わずに辿り着けない理由を言う",
        arguments: ["locked", "dangling"])
    func anUnreachablePlaceIsNamedWithItsReason(kind: String) throws {
        let root = try Self.emptyDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locked.appendingPathComponent("child", isDirectory: true),
            withIntermediateDirectories: true)
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path, withDestinationPath: root.appendingPathComponent("nowhere").path)
        chmod(locked.path, 0)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let (place, reason) =
            kind == "locked"
            ? (locked.appendingPathComponent("child").path, String(cString: strerror(EACCES)))
            : (dangling.path, "a symbolic link to something that is not there")

        let text = DoctorCommand.text(for: [place], workDirectory: nil, environment: Self.isolated())
        #expect(text.contains("Place: \(place) — cannot be reached: \(reason)"))
        #expect(!text.contains("nothing is there"))
        #expect(!text.contains("could not launch swift"))
    }

    /// 裏側。場所が在れば、いままでどおり道具立てを聞いて名乗る — `..` で始まる場所でも、
    /// 走らせた場所から解いた場所で聞く (#2314 の完了条件 1)。
    @Test("`..` で始まる場所でも、そこで道具立てを読んで名乗る")
    func aPlaceStartingWithDotDotIsReadThere() throws {
        let root = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let probe = root.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)

        let text = DoctorCommand.text(
            for: ["../probe"], workDirectory: nil, environment: Self.isolated(),
            currentDirectory: plain)
        #expect(text.contains("Place: \(probe.standardizedFileURL.path)\n"))
        #expect(!text.contains("Toolchain: \(DoctorCommand.unknown)"))
    }

    // MARK: - 道具立てを聞いて答えなかった理由 (#2522)

    /// **入れない場所を「swift を起こせなかった」の 1 文に畳まない。** stat に要るのは親の探索権
    /// だけなので、自身に x の無いディレクトリ (`chmod 000`) は `.directory` と読め、`swift` を
    /// 聞きに行って起こせずに投げる — その理由を `try?` が捨てて、唯一の既定文になっていた。
    @Test("入れない場所 (chmod 000) を渡すと、道具立ての行が入れないことを名乗る")
    func aPlaceWithoutSearchPermissionIsNamedOnTheToolchainLine() throws {
        let root = try Self.emptyDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }

        let text = DoctorCommand.text(
            for: [locked.path], workDirectory: nil, environment: Self.isolated())
        #expect(
            text.contains(
                "Toolchain: \(DoctorCommand.unknown) — swift could not start in \(locked.path): "
                    + String(cString: strerror(EACCES))))
        #expect(!text.contains("could not launch swift"))
    }

    /// 聞く口を差し替えて、答えなかった理由ごとの名乗りを固める。**127 は `PATH` を差し替えずに
    /// 通す** — 起こす側は `/usr/bin/env swift` を書き固めている。
    @Test("道具立てが答えなかった理由は、無い・起こせない・0 以外・空で別々に名乗る")
    func eachReasonTheToolchainDidNotAnswerIsNamedApart() {
        let place = URL(fileURLWithPath: "/sketch", isDirectory: true)
        func line(_ ask: @escaping (URL) throws(CommandFailure) -> (status: Int32, output: String))
            -> String
        {
            switch Toolchain.read(in: place, asking: ask) {
            case .version(let version): DoctorCommand.toolchainLine(version)
            case .unanswered(let reason): DoctorCommand.toolchainLine(nil, unanswered: reason)
            }
        }
        let unknown = DoctorCommand.unknown

        // `env` が 127 で終わった (`swift` が `PATH` に無い) — 無いと言う
        #expect(
            line { _ throws(CommandFailure) in throw .toolchainMissing("swift") }
                == "Toolchain: \(unknown) — swift was not found on the PATH — install the Xcode "
                + "command line tools")
        // 入れない・OS の事情で起こせない — 無いとは言わず、その理由を言う
        #expect(
            line { _ throws(CommandFailure) in
                throw .cannotLaunch(tool: "swift", place: "/sketch", reason: "Bad CPU type in executable")
            } == "Toolchain: \(unknown) — swift could not start in /sketch: Bad CPU type in executable")
        // 起きて 0 以外で終わった・何も言わなかった
        #expect(
            line { _ throws(CommandFailure) in (status: 69, output: "") }
                == "Toolchain: \(unknown) — swift --version exited with code 69")
        #expect(
            line { _ throws(CommandFailure) in (status: 0, output: "\n") }
                == "Toolchain: \(unknown) — swift --version printed nothing")
        // 答えたなら名乗りそのもの
        #expect(
            line { _ throws(CommandFailure) in (status: 0, output: "Apple Swift version 6.3.3\nTarget: x\n") }
                == "Toolchain: Apple Swift version 6.3.3")
    }

    /// **置き場の鍵は、読めない回にいままでどおり共有しない側へ倒れる** (#2522 の完了条件 5)。
    /// 理由を返す形にしても、`describe` の見え方は変えない。
    @Test("置き場の鍵が読む describe は、答えなかった回に nil のまま")
    func describeStaysNilWhenTheToolchainDoesNotAnswer() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        #expect(Toolchain.describe(in: missing) == nil)
        #expect(BuildDirectory.toolchainSegment(from: Toolchain.describe(in: missing)) == nil)
    }

    /// 文の形 (純関数)。
    @Test("聞かなかった道具立てと、聞いて読めなかった道具立てを言い分ける")
    func anUnaskedToolchainIsToldApart() {
        let place = URL(fileURLWithPath: "/nowhere", isDirectory: true)
        #expect(
            DoctorCommand.toolchainLine(nil, unaskedIn: place)
                == "Toolchain: \(DoctorCommand.unknown) — not asked, since swift cannot start in"
                + " /nowhere (see Place below)")
        // 聞いて読めなかった回は、理由を名乗る。理由を持たない回も「起こせなかった」とは決めつけない
        #expect(
            DoctorCommand.toolchainLine(nil, unanswered: "swift --version printed nothing")
                == "Toolchain: \(DoctorCommand.unknown) — swift --version printed nothing")
        #expect(
            DoctorCommand.toolchainLine(nil)
                == "Toolchain: \(DoctorCommand.unknown) — swift gave no answer")
        #expect(DoctorCommand.placeLine(place, presence: .directory) == "Place: /nowhere")
        #expect(DoctorCommand.placeLine(place, presence: .missing).contains("nothing is there"))
        #expect(
            DoctorCommand.placeLine(place, presence: .notDirectory).contains("not a directory"))
        let unreachable = DoctorCommand.placeLine(
            place, presence: .unreachable(reason: "Permission denied"))
        #expect(unreachable == "Place: /nowhere — cannot be reached: Permission denied")
    }

    /// 同梱の断片は実行時に組むので、スケッチのビルドは `metal` を起こさない。並べると
    /// 要らない Metal Toolchain を入れさせることになる
    /// ([#2351](https://github.com/mokume-metal/mokume/issues/2351))。
    @Test("環境の前提に、スケッチを組むのに使わない道具を並べない")
    func theShaderCompilerIsNotAPrerequisite() {
        var blind = Self.sound
        blind.canDraw = nil
        blind.toolchain = nil
        for environment in [Self.sound, blind] {
            let text = DoctorCommand.environmentLines(environment).joined(separator: "\n")
            #expect(!text.contains("Shader compiler"))
            #expect(!text.contains("Metal Toolchain"))
            #expect(!text.contains("MetalToolchain"))
        }
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

    /// 作り直しは通ったが子を起こせなかった回 (`ok: true, launched: false`) を「succeeded」と
    /// 言わない ([#2574](https://github.com/mokume-metal/mokume/issues/2574))。`doctor` は
    /// 「なぜ絵が止まっているか」を切り分ける口なので、そこで成功と言うと原因から遠ざかる。
    @Test("最後の作り直しが通っても起こせなかったなら、succeeded と言わず理由の頭を言う")
    func theLastBuildThatCouldNotStartIsNotCalledSucceeded() throws {
        let place = URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
        let reason = "Cannot start sketch: permission denied: /stub/.build/debug/sketch"
        var state = Self.state(place)
        state.lastBuild = DoctorCommand.LastBuild(
            ok: true, at: Date(timeIntervalSince1970: 0), launched: false,
            notStarted: reason)
        let text = DoctorCommand.stateLines(state).joined(separator: "\n")
        #expect(!text.contains("succeeded"))
        #expect(text.contains("built at"))
        #expect(text.contains("but not started: " + reason))

        // 起こせた回・`launched` を持たない古い記録は、従来どおり
        state.lastBuild = DoctorCommand.LastBuild(
            ok: true, at: Date(timeIntervalSince1970: 0), launched: true)
        #expect(DoctorCommand.stateLines(state).joined().contains("succeeded at"))
        state.lastBuild = DoctorCommand.LastBuild(ok: true, at: Date(timeIntervalSince1970: 0))
        #expect(DoctorCommand.stateLines(state).joined().contains("succeeded at"))
    }

    /// 記録 (JSON) から読んで、理由の頭が行まで届く。**読み手が `launched` を読み落とした
    /// 日に落ちる** — 行を組む側だけを見ると、記録を読む口の取りこぼしを見逃す。
    @Test("watch が置いた起こせなかった回の記録を、doctor が理由つきで読む")
    func theLastBuildIsReadWithItsLaunchedFlag() throws {
        let work = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let reason = "Cannot start sketch: permission denied"
        let report = BuildReport.notStarted(
            reason: reason, buildOutput: "[1/1] Compiling…", stamp: nil,
            configuration: "debug",
            timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
        let status = BuildReport.statusURL(under: work)
        try AtomicFile.writeJSON(report, to: status)

        let last = try #require(DoctorCommand.lastBuild(under: work))
        #expect(last.launched == false)
        #expect(last.notStarted == reason)
        let line = DoctorCommand.lastBuildLine(last)
        #expect(!line.contains("succeeded"))
        #expect(line.contains(reason))
    }

    /// **理由の欄を持たない古い記録の最初の行を、理由と読まない。** 欄ができる前の記録は、本文の頭が
    /// 理由ではなく作り直しの出力で、「but not started: Building for debugging...」と断定すると
    /// 誤りになる。理由が書かれていないことを言い、出力の在処を示す。
    @Test("理由を持たない古い起こせなかった記録は、理由を断定せず出力の在処を言う")
    func anOldNotStartedRecordDoesNotInventAReason() throws {
        let work = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let status = BuildReport.statusURL(under: work)
        try FileManager.default.createDirectory(
            at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old =
            #"{"schemaVersion":1,"ok":true,"status":0,"launched":false,"configuration":"debug","#
            + #""output":"Building for debugging...\n\nBuild complete!","timings":{"buildMs":1}}"#
        try Data(old.utf8).write(to: status)

        let last = try #require(DoctorCommand.lastBuild(under: work))
        #expect(last.launched == false)
        #expect(last.notStarted == nil)
        let line = DoctorCommand.lastBuildLine(last)
        #expect(!line.contains("Building for debugging"), "出力の最初の行を理由と読んでいる")
        #expect(!line.contains("succeeded"))
        #expect(line.contains("but not started"))
        #expect(line.contains("no reason"))
        #expect(line.contains(BuildReport.statusRelativePath))
    }

    /// **作り直しの失敗ではない記録を「failed」と言わない。** 見張りを終えたときの最後の記録は
    /// `ok: false` だが、本文の頭が失敗ではないと名乗っている (#1147)。普通の失敗は従来どおり。
    @Test("見張りを終えたときの記録は、作り直しの失敗と言わない")
    func aStoppedRebuildIsNotCalledAFailure() throws {
        for (output, expected) in [
            (WatchSession.stoppedRebuildNotice, BuildReport.Interruption.rebuildStopped),
            (WatchSession.notStartedNotice, BuildReport.Interruption.beforeFirstBuild),
        ] {
            let work = try Self.emptyDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let report = BuildReport.failed(
                status: 130, output: output, stamp: nil, configuration: "debug",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
            try AtomicFile.writeJSON(report, to: BuildReport.statusURL(under: work))

            let last = try #require(DoctorCommand.lastBuild(under: work))
            #expect(last.interruption == expected)
            let line = DoctorCommand.lastBuildLine(last)
            #expect(!line.contains("failed"), "失敗ではない記録を failed と言っている: \(line)")
            #expect(line.contains("not a build failure"))
        }

        // 普通の失敗は、従来どおり failed
        let work = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let broken = BuildReport.failed(
            status: 1, output: "error: boom", stamp: nil, configuration: "debug",
            timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
        try AtomicFile.writeJSON(broken, to: BuildReport.statusURL(under: work))
        let last = try #require(DoctorCommand.lastBuild(under: work))
        #expect(last.interruption == nil)
        #expect(DoctorCommand.lastBuildLine(last).contains("failed at"))
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
        #expect(text.contains("Ignored arguments doctor does not take"))
        #expect(text.contains("--wat"))
    }

    /// **値を取る選択肢は、値ごと脇へ置く** ([#2484](https://github.com/mokume-metal/mokume/issues/2484))。
    /// 宣言が無い頃は `doctor -c release` の `release` が場所になり、在らない `./release` を診たと
    /// 名乗っていた。
    @Test(
        "値を取る選択肢は値ごと脇へ置き、走らせた場所を診る",
        arguments: [
            (["-c", "release"], "-c release"),
            (["--configuration", "debug"], "--configuration debug"),
            (["--scratch-path", "out"], "--scratch-path out"),
            // 値が無くても止まらない。値が無かったと言う
            (["-c"], "-c (no value)"),
            // 空白入りの値は境目が読める
            (["--scratch-path", "my out"], "--scratch-path 'my out'"),
            // 値が `-` 始まりなら次の選択肢で、値に食わない
            (["-c", "--scratch-path", "out"], "-c (no value) --scratch-path out"),
        ])
    func declaredOptionsAreSetAsideWithTheirValue(arguments: [String], ignored: String) throws {
        let here = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: here) }
        let text = DoctorCommand.text(
            for: arguments, workDirectory: nil, environment: [:], home: here, currentDirectory: here)
        #expect(
            text.hasPrefix("Ignored arguments doctor does not take: \(ignored)\n"), "\(text)")
        // 値を場所として診ていない: 走らせた場所を診て、`release` という場所は出てこない
        #expect(text.contains("Place: \(here.path)\n"), "\(text)")
        #expect(!text.contains("nothing is there"), "\(text)")
    }

    /// **どの口の値を取る選択肢も、値を場所に取り違えない。** 宣言が `run`/`watch` の 2 つだけの写し
    /// だった頃は、`render` の `--fps 60` の `60` が場所になり、写しは `takesPlace` の有無までずれていた。
    /// 綴りは各口が実際に受けるもの (`render` の 3 つ・`bundle` の `--out`・`new` の 2 つ) を書き並べる。
    @Test(
        "どの口の値を取る選択肢でも、値は場所にならない",
        arguments: [
            ["-c", "release"], ["--configuration", "release"], ["--scratch-path", "out"],
            ["--fps", "60"], ["--seconds", "4"], ["--out", "motion.mov"],
            ["--path", "somewhere"], ["--local", "lib"],
        ])
    func everyVerbsOptionTakesItsValue(arguments: [String]) throws {
        let here = try Self.emptyDirectory()
        defer { try? FileManager.default.removeItem(at: here) }
        let text = DoctorCommand.text(
            for: arguments, workDirectory: nil, environment: [:], home: here, currentDirectory: here)
        #expect(
            text.hasPrefix(
                "Ignored arguments doctor does not take: \(arguments.joined(separator: " "))\n"),
            "\(text)")
        #expect(text.contains("Place: \(here.path)\n"), "\(text)")
    }

    /// **範囲外の語は値に取らない** — `doctor -c /path/to/sketch` は渡した場所を診る
    /// (変更前はそう診ていた)。値が無かったと名乗る。走らせる口と同じ範囲 (debug / release) を使う。
    @Test("構成の範囲外の語は値に取らず、渡した場所を診る")
    func aPlaceAfterTheConfigurationFlagIsStillThePlace() throws {
        let here = try Self.emptyDirectory()
        let sketch = here.appendingPathComponent("sketch", isDirectory: true)
        try FileManager.default.createDirectory(at: sketch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: here) }
        for flag in ["-c", "--configuration"] {
            let text = DoctorCommand.text(
                for: [flag, sketch.path], workDirectory: nil, environment: [:], home: here,
                currentDirectory: here)
            #expect(
                text.hasPrefix("Ignored arguments doctor does not take: \(flag) (no value)\n"),
                "\(text)")
            #expect(text.contains("Place: \(sketch.path)\n"), "\(text)")
        }
    }

    /// 選択肢の後ろに場所を置いても、診るのはその場所 (場所の読み取りは変わらない)。
    @Test("場所と選択肢を両方渡すと、場所を診て選択肢を脇へ置く")
    func thePlaceIsStillReadNextToAnOption() throws {
        let here = try Self.emptyDirectory()
        let sketch = here.appendingPathComponent("sketch", isDirectory: true)
        try FileManager.default.createDirectory(at: sketch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: here) }
        for arguments in [[sketch.path, "-c", "release"], ["-c", "release", sketch.path]] {
            let text = DoctorCommand.text(
                for: arguments, workDirectory: nil, environment: [:], home: here,
                currentDirectory: here)
            #expect(
                text.hasPrefix("Ignored arguments doctor does not take: -c release\n"), "\(text)")
            #expect(text.contains("Place: \(sketch.path)\n"), "\(text)")
        }
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
