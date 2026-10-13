// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 走らせたスケッチの終わり方が、道具の終わり方にどう出るか。
///
/// **終わる場所は `main.swift` の 1 つだけである。** 途中で `exit` を呼ぶと、名乗りも
/// 後始末もその catch を素通りする — 素通りしたことは出力からは読めないので、
/// 経路が 2 系統あること自体を型で塞いである。
@Suite("スケッチを走らせる", .signalStateKept)
struct RunCommandTests {
    /// 指定した終了コードで終わるだけの実行ファイルを置く。`seconds` だけ眠ってから終わる。
    private func makeExecutable(exiting status: Int32, after seconds: Double = 0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sketch")
        try "#!/bin/sh\nsleep \(seconds)\nexit \(status)\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// 自分の番号を `pid` へ書いて 30 秒眠るだけの実行ファイルを置く。合図の検査の子。
    ///
    /// **番号を書き終えてから名乗る** (途中を読ませない)。`exec` で番号を保ったまま眠る。
    private func makeSleeper() throws -> (directory: URL, marker: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("pid")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            echo $$ > '\(marker.path).tmp' && mv '\(marker.path).tmp' '\(marker.path)'
            exec sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, marker, executable)
    }

    /// 書かれた番号を読む。**期限までに書かれなければ `nil`** (期限は安全網・#564)。
    private nonisolated static func waitForPID(in marker: URL) -> pid_t? {
        let deadline = DispatchTime.now() + 30
        while DispatchTime.now() < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    /// 両方の流れへ 1 行ずつ書くだけの子。
    ///
    /// **偽の道具立てを `PATH` へ置く形は採らない。** `swift(_:in:capturing:errors:)` は
    /// 実行するものを `/usr/bin/env swift` に固定しているので、そちらからは差し替え
    /// られない。管の配線は `capture(_:capturing:errors:)` が持つので、任意の子を
    /// そこへ渡せば同じ配線を通せる。
    private func makeTalkativeChild() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo out; echo err >&2"]
        return process
    }

    @Test("掴む形で愚痴を混ぜると、子が stderr にだけ書いた行も出力に載る")
    func mergedErrorsReachTheOutput() throws {
        let result = try RunCommand.capture(
            makeTalkativeChild(), capturing: true, errors: .merge)

        #expect(result.status == 0)
        #expect(result.output.contains("err"), "stderr の行が出力に載っていない")
        #expect(result.output.contains("out"), "stdout の行まで落としている")
    }

    /// 混ぜる先が広がっていないことの裏。
    ///
    /// 出力をファイルパスや JSON として解く呼び出し (`binPath` / `dumpPackage` /
    /// `Toolchain.describe`) は、警告 1 行が混ざるだけで解けなくなる ([#731])。
    ///
    /// [#731]: https://github.com/mokume-metal/mokume/issues/731
    @Test("愚痴を混ぜない形では、stderr の行は出力に載らない")
    func inheritedErrorsStayOutOfTheOutput() throws {
        let result = try RunCommand.capture(
            makeTalkativeChild(), capturing: true, errors: .inherit)

        #expect(result.output.contains("out"))
        #expect(!result.output.contains("err"), "混ぜない形なのに stderr が出力へ入った")
    }

    /// `env` 越しに起こす子。`swift` を実際に `PATH` から消さずに、同じ経路を通す。
    private func makeChildThroughEnv(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = RunCommand.envURL
        process.arguments = arguments
        return process
    }

    /// `/usr/bin/env` 自体は必ず起動できるので、起動の失敗としては届かない。
    /// **見逃すと空の出力が「走らせるものが無い」と読まれ、Package.swift を疑わせる**
    /// ([#1157](https://github.com/mokume-metal/mokume/issues/1157))。
    @Test("env 越しに探した道具が無ければ、道具が無いと投げる")
    func aMissingToolIsThrownAsSuch() {
        let tool = "mokume-no-such-tool-\(UUID().uuidString)"
        #expect(throws: CommandFailure.toolchainMissing(tool)) {
            try RunCommand.capture(
                makeChildThroughEnv([tool, "build"]), capturing: true, errors: .discard)
        }
    }

    /// 裏側。道具が在って失敗した回は今までどおり呼び手へ終了コードを返す — そこから先の
    /// 「ビルドが通らない」「走らせるものが無い」の案内は、呼び手の経路が変わらず持つ。
    @Test("env 越しに見つかった道具の失敗は、投げずに終了コードを返す")
    func aFoundToolsFailureIsReturned() throws {
        let result = try RunCommand.capture(
            makeChildThroughEnv(["false"]), capturing: true, errors: .discard)
        #expect(result.status == 1)
    }

    @Test("env 越しでない子の 127 は、その子の終了コードとして返す")
    func a127FromAnyOtherChildIsReturned() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 127"]
        let result = try RunCommand.capture(process, capturing: true, errors: .discard)
        #expect(result.status == 127)
    }

    // MARK: - 起こせなかった理由 (#2314)

    private func missingPlace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-no-such-place-\(UUID().uuidString)", isDirectory: true)
    }

    /// **起こせなかったことを、道具が無いことと決めつけない。** `Process.run()` は作業
    /// ディレクトリが無いときも、実行ファイルが無いときと同じ失敗で投げる。`swift` は
    /// `/usr/bin/env` 越しに起こすので env 自体は在り、どれも道具の不在と読むと
    /// 「Xcode を入れ直せ」と人を遠ざける (`doctor` の規律 3)。
    @Test("作業ディレクトリが無くて swift を起こせなければ、道具が無いとは言わない")
    func aMissingPlaceIsNotAMissingTool() {
        let missing = missingPlace()
        let expected = CommandFailure.placeUnusable(
            tool: "swift", place: missing.path, presence: .missing)
        #expect(throws: expected) {
            try RunCommand.swift(["--version"], in: missing, capturing: true, errors: .discard)
        }
        #expect(expected.message.contains("\(missing.path): no such directory"))
        #expect(!expected.message.contains("Install the Xcode"), "道具の入れ直しへ案内している")
        #expect(expected.message.contains("Check the place you gave"))
    }

    @Test("作業ディレクトリがファイルなら、ディレクトリでないと言う")
    func aFileAsThePlaceIsNamed() throws {
        let executable = try makeExecutable(exiting: 0)
        #expect(
            throws: CommandFailure.placeUnusable(
                tool: "swift", place: executable.path, presence: .notDirectory)
        ) {
            try RunCommand.swift(["--version"], in: executable, capturing: true, errors: .discard)
        }
    }

    /// **入れない場所を「無い」と言わない** (#2314 の反証)。`Process.run()` は、`chmod 000` の
    /// 親の下を作業ディレクトリにしても `NSFileNoSuchFileError` で投げる (実測)。在る場所を
    /// 「no such directory」と言うと、在る場所を探させる。
    @Test("入れない場所で swift を起こせなければ、無いとは言わずに入れない理由を言う")
    func anUnreachablePlaceIsNotCalledMissing() throws {
        let locked = try makeLockedParent()
        defer { unlock(locked) }
        let place = locked.appendingPathComponent("child", isDirectory: true)
        let reason = String(cString: strerror(EACCES))
        let expected = CommandFailure.placeUnusable(
            tool: "swift", place: place.path, presence: .unreachable(reason: reason))
        #expect(throws: expected) {
            try RunCommand.swift(["--version"], in: place, capturing: true, errors: .discard)
        }
        #expect(!expected.message.contains("no such directory"))
        #expect(expected.message.contains(reason))
    }

    /// **場所に関わらない理由で、場所を疑わせない** (#2314 の反証)。場所はディレクトリで
    /// 実行ファイルも在るのに起こせなかった回 (ここでは中身が実行形式でない `ENOEXEC`) は、
    /// 「渡した場所を確かめよ」と言わない。
    @Test("場所でも実行ファイルの不在でもない理由なら、OS の事情を言い、場所を確かめよとは言わない")
    func aNonPlaceReasonDoesNotBlameThePlace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-noexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let garbage = directory.appendingPathComponent("sketch")
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE]).write(to: garbage)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: garbage.path)

        let expected = CommandFailure.cannotLaunch(
            tool: "sketch", place: directory.path, reason: String(cString: strerror(ENOEXEC)))
        #expect(throws: expected) {
            try RunCommand.launch(garbage, in: directory)
        }
        #expect(!expected.message.contains("Check the place you gave"), "場所を疑わせている")
        #expect(!expected.message.contains("no such directory"))
    }

    // MARK: - 場所の在り方 (#2314 の反証)

    /// 検索の権利を外した親 (`chmod 000`) を作る。**戻すのは呼び手** (`unlock`)。
    private func makeLockedParent() throws -> URL {
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: locked.appendingPathComponent("child", isDirectory: true),
            withIntermediateDirectories: true)
        chmod(locked.path, 0)
        return locked
    }

    private func unlock(_ locked: URL) {
        chmod(locked.path, 0o755)
        try? FileManager.default.removeItem(at: locked)
    }

    /// **「無い」は `ENOENT` のときだけ。** 入れない・symlink が巡る・symlink の宛先が無い、は
    /// 理由を言う。`.directory` になるのは ``WorkDirectory/directoryExists(at:)`` が `true` を
    /// 返すときだけ (同じ判定であること)。
    @Test("場所の在り方は、無い・ディレクトリでない・辿り着けないを分け、ディレクトリの判定は WorkDirectory と同じ")
    func presenceTellsMissingFromUnreachable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path, withDestinationPath: root.appendingPathComponent("nowhere").path)
        let loopA = root.appendingPathComponent("loop-a")
        let loopB = root.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.path)
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.path)
        let linkToDirectory = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: linkToDirectory.path, withDestinationPath: root.path)
        let locked = try makeLockedParent()
        defer { unlock(locked) }
        let behindLock = locked.appendingPathComponent("child", isDirectory: true)

        let cases: [(URL, GivenPath.Presence)] = [
            (root, .directory),
            (linkToDirectory, .directory),
            (file, .notDirectory),
            (root.appendingPathComponent("nope"), .missing),
            (behindLock, .unreachable(reason: String(cString: strerror(EACCES)))),
            (loopA, .unreachable(reason: String(cString: strerror(ELOOP)))),
            (dangling, .unreachable(reason: "a symbolic link to something that is not there")),
        ]
        for (place, expected) in cases {
            let presence = GivenPath.Presence.of(place)
            #expect(presence == expected, "\(place.lastPathComponent)")
            #expect(
                (presence == .directory) == WorkDirectory.directoryExists(at: place),
                "WorkDirectory と判定が割れた: \(place.lastPathComponent)")
        }
    }

    /// 裏側。実行ファイルが本当に無ければ、いままでどおり道具が無いと言う。
    @Test("実行ファイルそのものが無ければ、いままでどおり道具が無いと言う")
    func aMissingExecutableIsStillAMissingTool() {
        let process = Process()
        process.executableURL = missingPlace().appendingPathComponent("mokume-tool")
        #expect(throws: CommandFailure.toolchainMissing("mokume-tool")) {
            try RunCommand.capture(process, capturing: true, errors: .discard)
        }
    }

    /// スケッチを起こす口 (`launch`) も同じ読み替えをしていた — 起こせなければどれも
    /// 「走らせるものが無い (Package.swift の products を見よ)」だった。
    @Test("スケッチを在らない場所で起こせなければ、走らせるものが無いとは言わない")
    func aSketchInAMissingPlaceIsNotAMissingExecutable() throws {
        let executable = try makeExecutable(exiting: 0)
        let missing = missingPlace()
        #expect(
            throws: CommandFailure.placeUnusable(
                tool: "sketch", place: missing.path, presence: .missing)
        ) {
            try RunCommand.launch(executable, in: missing)
        }
        // 裏側。走らせるものが無ければ、いままでどおり
        let absent = missingPlace().appendingPathComponent("sketch")
        #expect(throws: CommandFailure.noExecutable(path: absent.path)) {
            try RunCommand.launch(absent, in: executable.deletingLastPathComponent())
        }
    }

    // MARK: - `..` で始まる場所 (#2314)

    /// 自分の作業ディレクトリ (シンボリックリンクを解いたもの) を `marker` へ書いて終わる子。
    private func makeWorkingDirectoryRecorder() throws -> (executable: URL, marker: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-pwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("pwd")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            /bin/pwd -P > '\(marker.path).tmp' && mv '\(marker.path).tmp' '\(marker.path)'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, marker)
    }

    /// シンボリックリンクを解いた絶対パス (`/var` → `/private/var`)。`/bin/pwd -P` と比べる。
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `走らせた場所/a/b` から打った、という形の置き場を作る。
    private func makeTypedFrom() throws -> (root: URL, typedFrom: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-dotdot-\(UUID().uuidString)", isDirectory: true)
        let typedFrom = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: typedFrom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a/c", isDirectory: true),
            withIntermediateDirectories: true)
        return (root, typedFrom)
    }

    /// **子は、渡した場所で動く。** 相対の `URL` のまま `Process.currentDirectoryURL` へ
    /// 渡すと、Foundation は先頭の `..` だけを落とす — `..`・`../..` は投げずに走らせた
    /// 場所で子を動かし、`../c` は `<走らせた場所>/c` を名指しして起動に失敗していた。
    @Test(
        "`..` で始まる場所を渡しても、スケッチは意図した場所で動く",
        arguments: [("..", "a"), ("../..", ""), ("../c", "a/c")])
    func aPlaceStartingWithDotDotRunsTheSketchThere(place: String, expected: String) throws {
        let (root, typedFrom) = try makeTypedFrom()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try makeWorkingDirectoryRecorder()
        let invocation = Invocation(place: place, currentDirectory: typedFrom)

        try RunCommand.launch(recorder.executable, in: invocation.directory)

        let ran = try String(contentsOf: recorder.marker, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        #expect(ran == Self.realPath(root.appendingPathComponent(expected, isDirectory: true)))
    }

    /// 見張りがスケッチを起こす口 (`WatchSession.Hooks.live`) も、同じ場所で起こす。
    @MainActor
    @Test("`..` で始まる場所を見張りに渡しても、スケッチは意図した場所で動く")
    func aPlaceStartingWithDotDotRunsTheWatchedSketchThere() throws {
        let (root, typedFrom) = try makeTypedFrom()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try makeWorkingDirectoryRecorder()
        let invocation = Invocation(place: "..", currentDirectory: typedFrom)
        let hooks = WatchSession.Hooks.live(in: invocation.directory, invocation: invocation)

        let process = try #require(
            hooks.launch(recorder.executable, invocation.directory, nil, nil),
            "見張りがスケッチを起こせなかった")
        // **待つ側が期限を持つ。** 越えたら子を殺して赤にする
        defer { if process.isRunning { process.terminate() } }
        let ran = try #require(Self.waitForText(in: recorder.marker), "期限までに書かれなかった")
        #expect(ran == Self.realPath(root.appendingPathComponent("a", isDirectory: true)))
    }

    /// 書かれた中身を読む。**期限までに書かれなければ `nil`** (期限は安全網・#564)。
    private nonisolated static func waitForText(in marker: URL) -> String? {
        let deadline = DispatchTime.now() + 30
        while DispatchTime.now() < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8) {
                return text.trimmingCharacters(in: .newlines)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    /// `swift` を起こす口 (`RunCommand.swift`) も、同じ場所で起こす。`dump-package` が
    /// 読んだ宣言で、どのパッケージの中で動いたかが分かる。
    @Test("`..` で始まる場所を渡しても、swift は意図したパッケージの中で動く")
    func aPlaceStartingWithDotDotRunsSwiftThere() throws {
        let (root, typedFrom) = try makeTypedFrom()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("a/c", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Sources/probe", isDirectory: true),
            withIntermediateDirectories: true)
        try """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "probe",
                products: [.executable(name: "probe", targets: ["probe"])],
                targets: [.executableTarget(name: "probe")]
            )
            """.write(
            to: package.appendingPathComponent("Package.swift"), atomically: true,
            encoding: .utf8)
        try "".write(
            to: package.appendingPathComponent("Sources/probe/main.swift"), atomically: true,
            encoding: .utf8)

        let invocation = Invocation(place: "../c", currentDirectory: typedFrom)
        let declared = try RunCommand.dumpPackage(in: invocation.directory)
        #expect(declared?.executableProductName == "probe")
    }

    @Test("0 以外で終わったスケッチは、終了コードを載せて投げる")
    func nonZeroExitsAreThrown() throws {
        let executable = try makeExecutable(exiting: 3)
        #expect(throws: CommandFailure.sketchExited(status: 3)) {
            try RunCommand.launch(executable, in: executable.deletingLastPathComponent())
        }
    }

    @Test("0 で終わったスケッチは、何も投げない")
    func cleanExitsAreQuiet() throws {
        let executable = try makeExecutable(exiting: 0)
        try RunCommand.launch(executable, in: executable.deletingLastPathComponent())
    }

    /// **道具の PID だけへ届く合図で、スケッチを孤児にしない**
    /// ([#1171](https://github.com/mokume-metal/mokume/issues/1171))。
    ///
    /// エージェントやスクリプトが道具だけを止める経路 (SIGTERM / SIGHUP) に加えて、**端末の
    /// Control + C (SIGINT) もこの経路である** — `Process` は子を別のプロセスグループに置くので、
    /// 端末が前面のグループへ配る SIGINT は道具にしか届かない
    /// ([#1618](https://github.com/mokume-metal/mokume/issues/1618))。ここでは検査の走者そのものを
    /// 道具に見立て、**自分のプロセスへ**合図を送る。
    ///
    /// **既定の受け口から始める。** 走者が SIGINT を無視で継いでいると、道具は受けない側へ倒れる
    /// (背面の起動の約束) ので、合図ごとに既定へ戻してから走らせ、終わったら継いだものへ戻す。
    ///
    /// **壊れた実装で走者ごと死なせない。** 受け口が置かれていなければ合図を送らずに失敗を
    /// 記録し、受け口が子へ渡さなければ期限で子を落として失敗を記録する — どちらでも
    /// `launch` の待ちは戻る。
    @Test(
        "道具だけへ終わりの合図が届いても、走らせていたスケッチを残さずに終わる",
        arguments: [SIGTERM, SIGHUP, SIGINT])
    func aStopSignalTakesTheSketchDownToo(stopSignal: Int32) throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Sender: @unchecked Sendable {
            var failures: [String] = []
            var pid: pid_t?
            let done = DispatchSemaphore(value: 0)
        }
        let (directory, marker, executable) = try makeSleeper()
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = SignalState.current()
        defer { kept.restore() }
        signal(stopSignal, SIG_DFL)
        let sender = Sender()
        // **並行プールに載せず、専用の糸で送る** (上の `theRunningChildCanBeTakenOutAndStopped`
        // と同じ理由)。期限はどれも安全網である (#564)
        Thread.detachNewThread {
            defer { sender.done.signal() }
            sender.pid = Self.waitForPID(in: marker)
            guard let pid = sender.pid else {
                sender.failures.append("スケッチが起きない")
                return
            }
            var current = sigaction()
            sigaction(stopSignal, nil, &current)
            guard current.__sigaction_u.__sa_handler != nil else {
                sender.failures.append("走らせている間、合図の受け口が置かれていない")
                kill(pid, SIGKILL)
                return
            }
            kill(getpid(), stopSignal)
            let gone = DispatchTime.now() + 10
            while kill(pid, 0) == 0, DispatchTime.now() < gone {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if kill(pid, 0) == 0 {
                sender.failures.append("道具が合図を受けたのに、スケッチが残っている")
                kill(pid, SIGKILL)
            }
        }

        #expect(throws: CommandFailure.stopped(signal: stopSignal)) {
            try RunCommand.launch(executable, in: directory)
        }
        #expect(sender.done.wait(timeout: .now() + 60) == .success, "合図を送る糸が戻らない")
        for failure in sender.failures { Issue.record(Comment(rawValue: failure)) }
        let pid = try #require(sender.pid)
        #expect(kill(pid, 0) != 0, "launch が戻った後もスケッチが残っている")

        var after = sigaction()
        sigaction(stopSignal, nil, &after)
        #expect(after.__sigaction_u.__sa_handler == nil, "走り終えた後に、合図の受け口を元へ戻していない")
    }

    /// **無視で継いだ SIGINT には受け口を置かない** — 背面 (`&`) で起こされた起動の約束を
    /// 上書きしない (子の `StopSignals.install` と同じ規則・判定も同じ `StopSignals.isIgnored`)。
    @Test("SIGINT は、無視で継いでいなければ受けて子へ渡す")
    func sigintIsForwardedUnlessInheritedAsIgnored() {
        var ignored = sigaction()
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        var standard = sigaction()
        standard.__sigaction_u.__sa_handler = SIG_DFL

        #expect(RunCommand.stopSignals(sigint: standard) == [SIGTERM, SIGHUP, SIGINT])
        #expect(RunCommand.stopSignals(sigint: ignored) == [SIGTERM, SIGHUP])
    }

    /// 上の規則を、**走らせている間の受け口で**確かめる。`launch` の既定がこの規則を通らずに
    /// SIGINT を足すと、背面で起こした `run` が端末の Control + C で止まる。
    ///
    /// 子は合図を介さずに落とす (道具が受けていないことを見るのが目的なので、走者へは送らない)。
    @Test("無視で継いだ SIGINT は、走らせている間も無視のままにしておく")
    func anIgnoredSigintStaysIgnoredWhileRunning() throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは子が落ちた後だけ**なので鍵は要らない。
        nonisolated final class Watcher: @unchecked Sendable {
            var failures: [String] = []
            let done = DispatchSemaphore(value: 0)
        }
        let (directory, marker, executable) = try makeSleeper()
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = SignalState.current()
        defer { kept.restore() }
        signal(SIGINT, SIG_IGN)

        let watcher = Watcher()
        Thread.detachNewThread {
            defer { watcher.done.signal() }
            guard let pid = Self.waitForPID(in: marker) else {
                watcher.failures.append("スケッチが起きない")
                return
            }
            if !StopSignals.isIgnored(RunCommand.currentAction(SIGINT)) {
                watcher.failures.append("無視で継いだ SIGINT に、受け口を置いた")
            }
            kill(pid, SIGTERM)
        }

        #expect(throws: CommandFailure.sketchExited(status: SIGTERM)) {
            try RunCommand.launch(executable, in: directory)
        }
        #expect(watcher.done.wait(timeout: .now() + 60) == .success, "見る糸が戻らない")
        for failure in watcher.failures { Issue.record(Comment(rawValue: failure)) }
        #expect(
            StopSignals.isIgnored(RunCommand.currentAction(SIGINT)), "走り終えた後に無視を戻していない")
    }

    // MARK: - 待つ間に割り込ませない (#1937)

    /// main の実行ループに載ったほかの仕事の代わり。**待ちの中で走ったら、そのとき見たものを残す。**
    ///
    /// 実行ループに載る仕事の実物は、駆動源 (`ScreenDisplayLink` → `SketchApplication.displayLinkFired()`
    /// → 旗 `sketchStopRequested` を読んで下ろす) と、見張りの巡回のタイマー
    /// (`WatchCommand.step` → 印 `watchStopRequested` を読む) である。どちらも合図の印を触る。
    final class Bystander {
        /// 子を待っている最中か。検査が待ちの前後で立てて下ろす。
        var waiting = false
        /// 待ちの中で走ったか。
        private(set) var ranInside = false
        /// 待ちの中で走ったときに見た宛先 (`runChildPID`)。
        private(set) var destinationSeenInside: pid_t = 0
        private var timer: Timer?

        /// 次の巡で鳴るタイマーを、main の実行ループへ載せる。鳴ると、宛先を書き換える
        /// (内側の `launch` は最後に 0 へ戻す)。**合図は送らない** — 待ちの中で走っても、
        /// 走者ごと落とさずに赤で名乗る。
        func arm() {
            let timer = Timer(timeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { self.fire() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// 鳴らなかったタイマーを畳む。**待ちの外では鳴らさない** — 後の検査の中で鳴ると、
        /// その検査の宛先を書き換える。
        func disarm() {
            timer?.invalidate()
            timer = nil
        }

        private func fire() {
            if waiting {
                ranInside = true
                destinationSeenInside = runChildPID
            }
            runChildPID = 0
        }
    }

    /// **待つ間に、ほかの仕事を入れ子で走らせない** ([#1937])。
    ///
    /// 待ちが main の実行ループを回すと、そこに載った仕事 (``Bystander`` の説明) が待ちの中で
    /// 走る。受け口・宛先を持ったまま待つ検査 (上の合図の検査) の前提が、待ちの最中に
    /// 書き換わる。ここでは、次の巡で鳴るタイマーを載せてから待ち、待ちの中で鳴らないことを見る。
    ///
    /// **main actor の待ち行列に積まれた仕事 (ほかの検査そのもの) は、`waitUntilExit()` の中でも
    /// 走らなかった** (Swift 6.4 の走者で実測・#1937)。入れ子に走るのは実行ループの仕事だけで、
    /// だからタイマーで見る。
    ///
    /// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
    @Test("走らせているスケッチを待つ間に、実行ループに載ったほかの仕事が割り込んで宛先を書き換えない")
    func nothingElseRunsWhileWaitingForTheSketch() throws {
        let executable = try makeExecutable(exiting: 0, after: 0.3)
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bystander = Bystander()
        bystander.arm()
        defer { bystander.disarm() }

        bystander.waiting = true
        try RunCommand.launch(executable, in: directory)
        bystander.waiting = false

        #expect(
            !bystander.ranInside,
            """
            launch の待ちの中でほかの仕事が走り、走らせている子の宛先 \
            (runChildPID = \(bystander.destinationSeenInside)) を書き換えた
            """)
    }

    /// 道具立て (`swift`) を待つ口も同じである。見張りの口 (`WatchCommand.run`) は、受け口を
    /// 控えてから戻すまでの間に、宣言を読む `swift` をここで待つ。
    @Test("道具立てを待つ間に、実行ループに載ったほかの仕事が割り込まない")
    func nothingElseRunsWhileWaitingForTheToolchain() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.3"]
        let bystander = Bystander()
        bystander.arm()
        defer { bystander.disarm() }

        bystander.waiting = true
        let result = try RunCommand.capture(process, capturing: false, errors: .inherit)
        bystander.waiting = false

        #expect(result.status == 0)
        #expect(!bystander.ranInside, "capture の待ちの中でほかの仕事が走った")
    }

    /// **合図で止めた回は、慣習の 128 + 番号で終わる。** スケッチの成否として 15 を返すと、
    /// 止めた側は「スケッチが自分で失敗した」と読む。
    @Test("合図で止めた回は、スケッチの失敗とは別の終わり方を名乗る")
    func aStoppedRunSaysItWasStopped() {
        #expect(CommandFailure.stopped(signal: SIGTERM).exitCode == 128 + SIGTERM)
        #expect(!CommandFailure.stopped(signal: SIGTERM).message.contains("sketch's own output"))
    }

    /// **引き継ぐのはスケッチの終了コードだけ。**
    ///
    /// 呼ぶ側が `run` に見ているのは道具の成否ではなくスケッチの成否である。組み立ての
    /// 失敗は道具自身の失敗なので、ほかの失敗と同じ 1 で終わる。
    @Test("道具自身の失敗は 1 で終わる")
    func onlyTheSketchExitCodePassesThrough() {
        #expect(CommandFailure.sketchExited(status: 3).exitCode == 3)
        #expect(CommandFailure.sketchExited(status: 130).exitCode == 130)
        #expect(CommandFailure.buildFailed(status: 3).exitCode == 1)
        #expect(CommandFailure.templatesMissing.exitCode == 1)
    }

    @Test("道具が足した失敗ではないことが、文面から読める")
    func theMessageSaysWhoseFailureItIs() {
        let message = CommandFailure.sketchExited(status: 3).message
        #expect(message.contains("3"))
        #expect(message.contains("the tool"))
    }

    /// **合図を渡すのは `run` だけである** ([#1120](https://github.com/mokume-metal/mokume/issues/1120))。
    ///
    /// 見張り (`watch`) は渡さない — 子は窓を持たず、確認は道具の側が出している
    /// ([ADR-0032] 決定 1)。渡さなければ載らないので、受け取る側は「無ければ確かめない」
    /// だけで済む。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("窓の × を確かめさせる合図は、渡したときだけ子の環境に載る")
    func theCloseSignalLandsOnlyWhenGiven() {
        #expect(RunCommand.childEnvironment([:])[StartupReads.closeConfirmation.key] == nil)
        #expect(
            RunCommand.childEnvironment([:], stamp: "abc", reportingRate: "debug")[
                StartupReads.closeConfirmation.key] == nil,
            "見張りが渡す組み合わせで合図が載っている")

        let carried = RunCommand.childEnvironment([:], confirmingCloseFor: "mokume run")
        #expect(carried[StartupReads.closeConfirmation.key] == "mokume run")
    }

    /// **区画の基準は、道具と子で同じ場所を指す** (#2323 の反証)。`MOKUME_WORK_DIR` が相対
    /// パスだと、道具は自分の作業ディレクトリ (走らせた場所) から解き、子は作業ディレクトリを
    /// スケッチに替えて起こされるので環境の相対値をスケッチから解く — `MOKUME_WORK_DIR=wd
    /// mokume watch ../probe` で、道具は `<走らせた場所>/wd` を、子は `<probe>/wd` を見て、
    /// 観測も入力も黙って噛み合わなくなる。子へは道具が解いた絶対パスを渡す。
    @Test("相対の MOKUME_WORK_DIR は、道具が解いた絶対パスで子へ渡る")
    func aRelativeWorkDirectoryReachesTheChildResolved() throws {
        let key = StartupReads.workDirectory.key
        let toolSide = try #require(WorkDirectory.given(environment: [key: "wd"]))

        let environment = RunCommand.childEnvironment([key: "wd"])
        #expect(environment[key] == toolSide.path)
        #expect(environment[key]?.hasPrefix("/") == true, "相対のまま子へ渡している")
        // 与えられていなければ、置かない (子は自分の既定に任せる)
        #expect(RunCommand.childEnvironment([:])[key] == nil)
        #expect(RunCommand.childEnvironment([key: ""])[key] == "", "空は与えられていない扱いのまま運ぶ")

        // 子を、道具とは別の作業ディレクトリ (スケッチ) で起こし、受け取った値を
        // その場所から解く — 子が見る区画の基準である
        let sketch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-workdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sketch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sketch) }
        let marker = sketch.appendingPathComponent("given")
        let child = sketch.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(key)" > '\(marker.path)'
            """.write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)

        try RunCommand.launch(child, in: sketch, environment: environment)

        let received = try String(contentsOf: marker, encoding: .utf8)
        let childSide = URL(fileURLWithPath: received, isDirectory: true, relativeTo: sketch)
            .standardizedFileURL
        #expect(childSide.path == toolSide.standardizedFileURL.path, "子が別の区画を見る")
    }

    // MARK: - 出来上がりの置き場 (#1067)

    /// **置き場を聞くのに `swift` を 1 本起こす。** 見張りは宣言が変わるまでそれを持ち回る
    /// ので (``BuildResolver``)、渡されたら聞き直さないことがここの約束である —
    /// 聞き直すと、手元の実測で毎回 315 ms が作り直しの時間に乗る
    /// ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
    ///
    /// **`Package.swift` の無い場所で見る。** 作り直しそのものは即座に失敗するが、
    /// 置き場をどこから得たかは結果に載るので、そこだけを見れば `swift build` の完走を
    /// 待たずに済む。
    @Test("置き場を渡した回は、道具立てに聞き直さない")
    func aGivenBinPathIsUsedAsIs() throws {
        let directory = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let given = directory.appendingPathComponent("given-bin", isDirectory: true)

        let rebuilt = try RunCommand.rebuild(
            in: directory, context: testContext(), capturing: true, binPath: given)

        #expect(rebuilt.binPath == given, "渡した置き場を使わず、道具立てに聞き直している")
    }

    /// 裏。**渡さなければ今までどおり聞く** — `run` と `bundle` はこちらを通る。
    ///
    /// **ここだけは宣言のあるディレクトリで見る。** Swift 6.4 の
    /// `swift build --show-bin-path` は `Package.swift` の無い場所では置き場を 1 つも
    /// 印字せずに失敗するので、空のディレクトリでは「聞いた形」そのものを作れない
    /// ([#1275](https://github.com/mokume-metal/mokume/issues/1275))。中身の無い宣言で
    /// 足りるので、作り直しの完走を待たない作りは変わらない。
    @Test("置き場を渡さなければ、道具立てに聞く")
    func anAbsentBinPathIsAskedFor() throws {
        let directory = try makeDeclaredDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rebuilt = try RunCommand.rebuild(
            in: directory, context: testContext(), capturing: true)

        // place を組み立てて確かめない (道具立てが並びを変えた日に黙って別の場所を指す)。
        // **このパッケージの下の `.build` であること**だけを見る
        #expect(
            rebuilt.binPath.path.contains(directory.lastPathComponent),
            "聞いた先が別のパッケージの下になっている")
        #expect(rebuilt.binPath.lastPathComponent != "given-bin")
        #expect(rebuilt.binPath.path.contains(".build"), "道具立てが答える置き場の形をしていない")
    }

    // MARK: - 作り直しが先に消すもの (#2502)

    /// 置き場 (`bin`) とその周りの、消えてはならないものを並べた木。
    ///
    /// ```
    /// <root>/
    ///   package/            Package.swift の無い場所 (作り直しは即座に失敗する)
    ///   layout/
    ///     marker.txt        bin の親にある印
    ///     victim/keep.txt   bin の隣
    ///     bin/
    ///       other.txt       bin の中の別のファイル
    ///       victim/keep.txt bin の中の別のディレクトリ (`sub/../victim` の行き先)
    ///       sub/
    /// ```
    private struct Layout {
        let root: URL
        let package: URL
        let bin: URL
        /// 消えてはならない印のファイル。
        let kept: [URL]

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-rebuild-guard-\(UUID().uuidString)", isDirectory: true)
            let layout = root.appendingPathComponent("layout", isDirectory: true)
            package = root.appendingPathComponent("package", isDirectory: true)
            bin = layout.appendingPathComponent("bin", isDirectory: true)
            let manager = FileManager.default
            for directory in [
                package, bin.appendingPathComponent("victim"), bin.appendingPathComponent("sub"),
                layout.appendingPathComponent("victim"),
            ] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            kept = [
                layout.appendingPathComponent("marker.txt"),
                layout.appendingPathComponent("victim/keep.txt"),
                bin.appendingPathComponent("other.txt"),
                bin.appendingPathComponent("victim/keep.txt"),
            ]
            for file in kept { try "keep".write(to: file, atomically: true, encoding: .utf8) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func rebuild(product: String) throws -> RunCommand.Rebuilt {
            try RunCommand.rebuild(
                in: package, context: testContext(product: product), capturing: true, binPath: bin)
        }
    }

    /// **作り直しが先に消すのは、置き場の直下にある自分の前の産物 (`<product>` と
    /// `<product>.dSYM`) だけ**である。product の名前は `Package.swift` から来るが、
    /// 名前から作った場所を検めずに渡すと、`..` を含む名前は置き場の外を指す
    /// ([#2502](https://github.com/mokume-metal/mokume/issues/2502))。SwiftPM がそういう名前を
    /// 断るかには頼らない。
    @Test(
        "product の名前が置き場の外・置き場そのものを指す形でも、置き場の外と中の別のものは消えない",
        arguments: ["../victim", "..", ".", "sub/../victim", "../bin", "victim/..", "sub/.."])
    func rebuildNeverRemovesOutsideItsOwnProducts(product: String) throws {
        let layout = try Layout()
        defer { layout.remove() }

        try layout.rebuild(product: product)

        for file in layout.kept {
            #expect(
                FileManager.default.fileExists(atPath: file.path),
                "product \(product) で、消えてはならないものが消えた: \(file.path)")
        }
        #expect(FileManager.default.fileExists(atPath: layout.bin.path), "置き場そのものが消えた")
    }

    /// 陽性側。**いつもの名前は従来どおり先に消える** — 前の版が残ると「いま建ったか」を
    /// 言えない (`rebuild` の消す理由)。守りが広すぎて消さなくなっていないことを見る。
    @Test("いつもの名前なら、置き場の直下の実行ファイルと dSYM は先に消える")
    func rebuildStillRemovesItsOwnPreviousProducts() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let executable = layout.bin.appendingPathComponent("Grain")
        let symbols = layout.bin.appendingPathComponent("Grain.dSYM/Contents", isDirectory: true)
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: symbols, withIntermediateDirectories: true)

        try layout.rebuild(product: "Grain")

        #expect(!FileManager.default.fileExists(atPath: executable.path), "前の実行ファイルが残った")
        #expect(
            !FileManager.default.fileExists(
                atPath: layout.bin.appendingPathComponent("Grain.dSYM").path),
            "前の dSYM が残った")
        for file in layout.kept {
            #expect(FileManager.default.fileExists(atPath: file.path), "別のものが消えた: \(file.path)")
        }
    }

    /// **消さなくなった分、`..` などが「建った実行ファイル」として返ってはならない** (#2502 の反証)。
    /// `isExecutableFile` はディレクトリにも真を返すので、`bin/..` (= `bin` の親) や
    /// `bin/victim` (ディレクトリ) を、実在する実行ファイルとして名乗っていた。
    @Test(
        "product の名前が置き場の直下を指さない・ディレクトリを指すなら、建った実行ファイルとは言わない",
        arguments: ["../victim", "..", ".", "sub/../victim", "../bin", "victim/..", "sub/..", "victim"])
    func rebuildNeverReportsADirectoryAsBuilt(product: String) throws {
        let layout = try Layout()
        defer { layout.remove() }

        let rebuilt = try layout.rebuild(product: product)

        #expect(rebuilt.executable == nil, "product \(product) で、建ったと言っている: \(String(describing: rebuilt.executable))")
    }

    /// 「建った」と見るのは、置き場の直下にある通常のファイルで実行できるものだけ。
    @Test("建った実行ファイルは、直下の実行できる通常のファイルだけ")
    func onlyARegularExecutableFileInTheBinCountsAsBuilt() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let manager = FileManager.default
        let tool = layout.bin.appendingPathComponent("Grain")
        try "binary".write(to: tool, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let plain = layout.bin.appendingPathComponent("Plain")
        try "text".write(to: plain, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)

        #expect(RunCommand.builtExecutable(named: "Grain", in: layout.bin) == tool)
        #expect(RunCommand.builtExecutable(named: "Plain", in: layout.bin) == nil, "実行できないものを建ったと言った")
        #expect(RunCommand.builtExecutable(named: "victim", in: layout.bin) == nil, "ディレクトリを建ったと言った")
        #expect(RunCommand.builtExecutable(named: "Absent", in: layout.bin) == nil)
    }

    /// **守りは、ファイルの在る・無しで結果を変えない** (#2502 の反証)。`standardizedFileURL` は
    /// 在るパスの先頭 `/private` を外し、在らないパスはそのまま返すので、`/tmp`・`/var` 配下の置き場で
    /// 行き先の無い symlink (`bin/<product>` が dangling) だけが、従来は消せたのに守りで空になった。
    @Test("/tmp 配下でも、行き先の無い symlink は前の産物として消える")
    func aDanglingLinkUnderTmpIsStillRemoved() throws {
        // `/tmp` は `/private/tmp` への symlink。`temporaryDirectory` (`/var/folders/…`) も同じ形だが、
        // 症状の出る綴りを名指しする
        let root = URL(fileURLWithPath: "/private/tmp/mokume-dangling-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = bin.appendingPathComponent("Dang")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/nonexistent-\(UUID().uuidString)")

        #expect(RunCommand.previousArtifacts(of: "Dang", in: bin).first?.lastPathComponent == "Dang")

        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        _ = try RunCommand.rebuild(
            in: package, context: testContext(product: "Dang"), capturing: true, binPath: bin)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
            "行き先の無い symlink が残った")
    }

    /// 置き場の綴りによらない: `..` を含む・symlink を通る・在る/無い。
    @Test("置き場が .. を含む綴り・symlink でも、直下の産物は前の産物として返る")
    func theBinSpellingDoesNotChangeTheAnswer() throws {
        let root = URL(fileURLWithPath: "/tmp/mokume-spell-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: real.appendingPathComponent("bin").path)
        defer { try? FileManager.default.removeItem(at: root) }

        let spellings = [
            real.appendingPathComponent("bin"),
            URL(fileURLWithPath: root.path + "/sub/../real/bin", isDirectory: true),
            link,
            URL(fileURLWithPath: root.path + "/absent/bin", isDirectory: true),  // 在らない
            URL(fileURLWithPath: "/private" + root.path + "/real/bin", isDirectory: true),
        ]
        for bin in spellings {
            let found = RunCommand.previousArtifacts(of: "Grain", in: bin)
            #expect(found.map(\.lastPathComponent) == ["Grain", "Grain.dSYM"], "\(bin.path)")
            #expect(RunCommand.previousArtifacts(of: "../victim", in: bin).isEmpty, "\(bin.path)")
            // `..` 自身は返らない (`...dSYM` は直下の通常の名前なので返ってよい)
            #expect(
                RunCommand.previousArtifacts(of: "..", in: bin).map(\.lastPathComponent)
                    == ["...dSYM"], "\(bin.path)")
        }
    }

    // MARK: - 置き場の答えの読み方 (#2316)

    /// **終了コードを見る。** 空の出力だけを見ていた頃は、道具立てが断った回
    /// (`--show-bin-path -c Release` が usage を出して非 0 で終わる) を「Package.swift に
    /// 実行ファイルが無い」と名乗っていた ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。
    /// 原因が道具立てなのに宣言を疑わせる形は、`env` の 127 で塞いだ #1157 と同類である。
    ///
    /// **答えは偽の子から取る。** `binPath(in:context:)` は `/usr/bin/env swift` を書き固めて
    /// いるので、管の配線を持つ `capture` に任意の子を渡し、その答えを同じ読み手に通す (#731)。
    @Test("置き場を聞かれた道具立てが 0 以外で終わったら、宣言ではなく道具立ての失敗として名乗る")
    func aRefusedBinPathIsTheToolchainsFailure() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo 'error: usage' >&2; exit 64"]
        let answer = try RunCommand.capture(process, capturing: true, errors: .discard)
        let asked = ["build", "--show-bin-path", "-c", "Release"]

        let thrown = #expect(throws: CommandFailure.self) {
            try RunCommand.binPath(from: answer, asking: asked)
        }
        #expect(
            thrown == .toolchainFailed(command: "swift build --show-bin-path -c Release", status: 64))
        let message = try #require(thrown).message
        #expect(!message.contains("Package.swift"), "道具立ての失敗なのに宣言を疑わせている: \(message)")
        #expect(message.contains("swift build --show-bin-path -c Release"), "何を打ったかを名乗っていない")
        #expect(message.contains("64"), "終了コードを名乗っていない")
        // **見張りはこの文面を記録に載せ、窓口の読み手には端末の「上」が無い** (反証の指摘)。
        // 理由が流れた先と、それをもう一度読む手を言う
        #expect(!message.contains("above"), "記録の読み手に無い「上」を指している: \(message)")
        #expect(message.contains("standard error"), "理由の行き先を名乗っていない: \(message)")
    }

    /// 読み方の境目。**0 以外なら、道が印字されていても読まない** — 終了コードを見ずに
    /// 出力の有無だけで決めると、途中まで書いて断った回の道を採る。0 でも空なら答えていない。
    @Test("置き場は 0 で終わって道を答えたときだけ読み、それ以外は道具立ての失敗にする")
    func onlyAnAnsweredBinPathIsRead() throws {
        let asked = ["build", "--show-bin-path"]
        #expect(
            try RunCommand.binPath(
                from: (0, "/sketch/.build/arm64-apple-macosx/debug\n"), asking: asked)
                == URL(fileURLWithPath: "/sketch/.build/arm64-apple-macosx/debug", isDirectory: true))
        #expect(throws: CommandFailure.toolchainFailed(command: "swift build --show-bin-path", status: 1)) {
            try RunCommand.binPath(from: (1, "/sketch/.build/debug\n"), asking: asked)
        }
        #expect(throws: CommandFailure.toolchainFailed(command: "swift build --show-bin-path", status: 0)) {
            try RunCommand.binPath(from: (0, " \n"), asking: asked)
        }
    }

    /// 宣言だけを置いたディレクトリ。**中身は持たない** — 置き場を答えられれば足りる。
    private func makeDeclaredDirectory() throws -> URL {
        let directory = try makeEmptyDirectory()
        try """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "bin-path-probe", targets: [.target(name: "Probe")])
            """.write(
            to: directory.appendingPathComponent("Package.swift"), atomically: true,
            encoding: .utf8)
        return directory
    }

    private func makeEmptyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-binpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 走っている作り直しを掴む (#1147)

    /// **作り直しは `swift` を何度か呼ぶ** (`--show-bin-path` → `build` → 場合により
    /// `dump-package`)。止めると決めた後に 2 本目を起こすと、それが新しく `.build` の鍵を
    /// 握って、止めたはずの作り直しが続く ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    @Test("止めると決めた後は、次の子を起こさずに投げる")
    func aStoppedBuildLaunchesNothingMore() {
        let running = RunningBuild()
        #expect(running.stop() == nil, "何も起こしていないのに子を掴んでいる")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        #expect(throws: CommandFailure.rebuildStopped) {
            try RunCommand.capture(process, capturing: true, errors: .discard, running: running)
        }
        #expect(process.processIdentifier == 0, "止めると決めた後に子を起こした")
    }

    /// **掴んだ子は、終わったら手放す。** 手放さないと、次に止める口は終わった子を返し、
    /// 呼ぶ側は居ない相手に合図を撃つことになる。
    @Test("走っている子は止める口から取り出せて、終われば手放される")
    func theRunningChildCanBeTakenOutAndStopped() throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Outcome: @unchecked Sendable {
            var status: Int32?
            let done = DispatchSemaphore(value: 0)
        }
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-running-build-\(UUID().uuidString)")
        let running = RunningBuild()
        let outcome = Outcome()
        // **並行プールに載せず、専用の糸で待つ。** `Task.detached` で待たせたら、`make ci-check`
        // の並列の下でプールの糸が他の検査に塞がれ、60 秒待っても子が起きなかった (CI で実測)。
        // `Process` は閉じた中で作る (送れる値ではない)。起きたことは子が印を置いて名乗る
        //
        // **印は組み込みのリダイレクトで置き、`touch` を呼ばない。** `/bin/sh` (bash) は前面の子を
        // 待つ間に SIGINT を受けても、子が普通に終われば「子が処理した」とみなして続きを実行する。
        // `touch` が終わってから刈り取るまでの窓に撃つと `exec sleep 30` まで進んで眠り切り、
        // 待ちの期限と同時に赤くなった — 負荷の下ほど窓は広い (#1166)。子を待たなければ窓は無い
        Thread.detachNewThread {
            defer { outcome.done.signal() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ": > '\(marker.path)'; exec sleep 30"]
            outcome.status = try? RunCommand.capture(
                process, capturing: true, errors: .discard, running: running
            ).status
        }
        // **待つ側が期限を持つ** (#564)。期限は安全網である
        let deadline = DispatchTime.now() + 30
        while !FileManager.default.fileExists(atPath: marker.path), DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let child = try #require(running.stop(), "走っている子を掴んでいない")
        child.interrupt()
        #expect(outcome.done.wait(timeout: .now() + 30) == .success, "止めた子を待つ糸が戻らない")
        #expect(outcome.status == SIGINT, "取り出した子が、止めた合図で終わっていない")
        #expect(running.stop() == nil, "終わった子を掴んだままでいる")
    }
}
