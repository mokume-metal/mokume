// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 固定の fps で動きを書き出す口 (`render`・[#1282])。
///
/// **ビルドの前に止まるべきものは、ビルドの前に止まる。** 引数の誤りを数分のビルドの後で
/// 知らせると、直して打ち直すたびにまたビルドを待つことになる。子が窓を開かずに書き出す
/// ことは `SketchApplicationRenderTests` (MokumeCoreTests) が本物の GPU で見る。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
@Suite("固定の fps で書き出す口", .signalStateKept)
struct RenderCommandTests {
    /// `--out` の相対パスを解く基準 (打った場所)。
    private static let typedFrom = URL(fileURLWithPath: "/tmp/typed-here", isDirectory: true)

    private func parse(_ arguments: [String]) throws(CommandFailure) -> RenderCommand.Options {
        try RenderCommand.parse(arguments, currentDirectory: Self.typedFrom)
    }

    /// 使い方の誤りとして止まったか。**文面に `needle` を含むこと**まで見る — 止まっても、
    /// 何を直せばよいかが書かれていなければ打ち直せない。
    private func expectUsage(
        _ arguments: [String], mentioning needle: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectUsage(arguments, mentioningAll: [needle], sourceLocation: sourceLocation)
    }

    /// 上と同じで、文面に `needles` を**全部**含むことまで見る。
    ///
    /// - Parameter typedFrom: 打った場所。
    private func expectUsage(
        _ arguments: [String], mentioningAll needles: [String],
        typedFrom: URL = RenderCommandTests.typedFrom,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try RenderCommand.parse(arguments, currentDirectory: typedFrom)
            Issue.record(
                "止まらなかった: 打った場所 \(typedFrom.path) で \(arguments)",
                sourceLocation: sourceLocation)
        } catch {
            guard case .usage(let text) = error else {
                Issue.record("使い方の誤りではない: \(error)", sourceLocation: sourceLocation)
                return
            }
            for needle in needles {
                #expect(
                    text.contains(needle), "文面に \(needle) が無い: \(text)",
                    sourceLocation: sourceLocation)
            }
        }
    }

    /// `--out` の形が断られたか。**文面の肝まで見る** — `--out` の名と、打った綴りと、番号の
    /// 場所がファイル名に要ること。`--out` とだけ言われても、`take#1/` の何が悪いのかは
    /// 分からない。
    private func expectOutRefused(
        _ out: String, typedFrom: URL = RenderCommandTests.typedFrom,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectUsage(
            ["--fps", "10", "--seconds", "0.5", "--out", out],
            mentioningAll: ["--out", "in the file name", ": \(out)"], typedFrom: typedFrom,
            sourceLocation: sourceLocation)
    }

    // MARK: - 解ける形 (完了条件 1・2)

    @Test("場所・構成・置き場と、fps・秒数・行き先を受け、枚数は fps × 秒数になる")
    func takesEverythingAndCountsTheFrames() throws {
        let options = try parse([
            "Cast", "-c", "release", "--scratch-path", ".build", "--fps", "60", "--seconds",
            "48", "--out", "/tmp/cast.mov",
        ])
        #expect(
            options.invocation
                == Invocation(
                    place: "Cast", configuration: "release", scratchPath: ".build",
                    currentDirectory: Self.typedFrom))
        #expect(options.request.frameRate == 60)
        #expect(options.request.frameCount == 2880)
        #expect(options.request.destination == "/tmp/cast.mov")
    }

    /// **場所・置き場・行き先は、どれも打った場所から解く** (#2320・#2323 の判断・案 A)。
    /// 置き場だけがスケッチの場所から解かれていたので、`plain/` で
    /// `render ../probe --scratch-path sp --out o.mov` と打つと、書いたものは `plain/o.mov`
    /// なのに組み立ての置き場は `probe/sp` になっていた。
    @Test("場所・置き場・行き先は、どれも打った場所から解く")
    func everyPathIsResolvedFromWhereItWasTyped() throws {
        let plain = URL(fileURLWithPath: "/work/plain", isDirectory: true)
        let options = try RenderCommand.parse(
            [
                "../probe", "--scratch-path", "sp", "--fps", "10", "--seconds", "0.1", "--out",
                "o.mov",
            ], currentDirectory: plain)
        #expect(options.invocation.directory.path == "/work/probe")
        #expect(options.invocation.scratchDirectory?.path == "/work/plain/sp")
        #expect(options.request.destination == "/work/plain/o.mov")
    }

    /// **子の作業ディレクトリはスケッチの場所である。** 相対のまま渡すと、書いたものが
    /// スケッチの中に出来て、打った場所には何も無い。
    @Test("--out の相対パスは、打った場所から解いて絶対パスで渡す")
    func aRelativeOutIsResolvedFromWhereItWasTyped() throws {
        let movie = try parse(["--fps", "30", "--seconds", "2", "--out", "renders/a.mov"])
        #expect(movie.request.destination == "/tmp/typed-here/renders/a.mov")
        let series = try parse(["--fps", "30", "--seconds", "2", "--out", "../f-####.png"])
        #expect(series.request.destination == "/tmp/f-####.png")
    }

    /// 10 進で掛ける。2 進の浮動小数だと `100 × 1.1` が 110 にならず (110.00000000000001)、正しい組まで断る。
    @Test("秒数は小数でも受け、fps × 秒数が整数なら通す")
    func fractionalSecondsThatMakeWholeFramesPass() throws {
        func frames(_ fps: String, _ seconds: String) throws -> Int {
            try parse(["--fps", fps, "--seconds", seconds, "--out", "/a.mov"]).request.frameCount
        }
        #expect(try frames("30", "0.1") == 3)
        #expect(try frames("100", "1.1") == 110)
        #expect(try frames("24", "2.5") == 60)
        // 境目: 1 枚ちょうど
        #expect(try frames("1", "1") == 1)
    }

    // MARK: - ビルドの前に止まる (完了条件 1)

    @Test(
        "--fps・--seconds・--out のどれかが欠けたら、欠けたものを名指して止まる",
        arguments: [
            (["--seconds", "2", "--out", "/a.mov"], "--fps"),
            (["--fps", "30", "--out", "/a.mov"], "--seconds"),
            (["--fps", "30", "--seconds", "2"], "--out"),
        ])
    func aMissingFlagStopsWithItsName(arguments: [String], missing: String) {
        expectUsage(arguments, mentioning: missing)
    }

    /// **枚数は丸めない。** 丸めると、頼んだ長さと書き出した長さが黙って食い違う。
    @Test("fps × 秒数が整数にならない組は、丸めずに止まる")
    func aFractionalFrameCountIsRefused() {
        expectUsage(["--fps", "30", "--seconds", "0.05", "--out", "/a.mov"], mentioning: "1.5")
        expectUsage(
            ["--fps", "60", "--seconds", "0.001", "--out", "/a.mov"],
            mentioning: "not a whole number")
    }

    @Test(
        "fps は 1 以上の整数だけを受ける",
        arguments: ["0", "-30", "29.97", "abc", ""])
    func aBadFrameRateIsRefused(rate: String) {
        expectUsage(["--fps", rate, "--seconds", "2", "--out", "/a.mov"], mentioning: "--fps")
    }

    /// **`.mov` の時刻は 1/90 000 秒で数える** ([#2307])。それより速いと隣の枚が同じ時刻へ
    /// 丸まり、書く係が外れて開けない `.mov` が残っていた (`--fps 100000`)。走らせる前に、
    /// 上限を名乗って止まる。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    @Test("--fps が .mov の刻みを越えたら、上限を名乗ってビルドの前に止まる")
    func aFrameRateBeyondTheMovieTimescaleIsRefused() throws {
        expectUsage(
            ["--fps", "90001", "--seconds", "1", "--out", "/a.mov"],
            mentioningAll: ["--fps", "90000", ": 90001"])
        // 境目: 刻みちょうどは通る。連番は時刻を書かないので、刻みを越えても通る
        #expect(
            try parse(["--fps", "90000", "--seconds", "1", "--out", "/a.mov"]).request.frameRate
                == 90_000)
        #expect(
            try parse(["--fps", "90001", "--seconds", "1", "--out", "/f-####.png"]).request
                .frameRate == 90_001)
    }

    @Test(
        "秒数は 0 より大きい数だけを受ける",
        arguments: ["0", "-1", "abc", "2s", "inf", "nan", "0x10"])
    func aBadLengthIsRefused(seconds: String) {
        expectUsage(["--fps", "30", "--seconds", seconds, "--out", "/a.mov"], mentioning: "--seconds")
    }

    /// 形の規則は撮る係のもの。`.mov` か、番号の入る場所 (`#`) を持つ連番。
    @Test("行き先が動画でも連番でもなければ止まる", arguments: ["/a.png", "/a", "/a.mp4"])
    func anUnrecordableOutIsRefused(out: String) {
        expectOutRefused(out)
    }

    /// **打った場所の名前の `#` は番号の場所ではない** ([#2313])。`--out` は打った場所から
    /// 絶対パスにしてから形を見るので、パス全体から `#` を探すと、`#` の無い `still.png` まで
    /// 連番として受け、断られずに 0 で終わる。書いたものは隣の `take01/`… にできる。
    ///
    /// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
    @Test("打った場所の名前に # があっても、ファイル名に # の無い --out は止まる")
    func aHashInWhereItWasTypedDoesNotMakeASeries() throws {
        let typedFrom = URL(fileURLWithPath: "/tmp/take#1", isDirectory: true)
        expectOutRefused("still.png", typedFrom: typedFrom)

        // 同じ場所でも、ファイル名に `#` があれば連番として受け、置き場はそのまま
        let series = try RenderCommand.parse(
            ["--fps", "10", "--seconds", "0.5", "--out", "f-##.png"], currentDirectory: typedFrom)
        #expect(series.request.destination == "/tmp/take#1/f-##.png")
    }

    /// **形は打った綴りで見る** ([#2313] の反証)。絶対パスにすると末尾の `/` と `.`・`..` が
    /// 消え、番号の場所を探す最後の部品が打った綴りと変わる。`take#1/` (フォルダを指した
    /// つもり) が `<打った場所>/take#1` になり、`take#1` の `#` を番号にして、拡張子の無い
    /// `take01`・`take11`… を打った場所に並べて 0 で終わっていた。書く API の側
    /// (`beginRecord("take#1/")`) は断るので、同じ綴りで道具とスケッチの判定が食い違っていた。
    ///
    /// 打った場所は `#` の無い所にする (打った場所の `#` は上の検査が見る)。
    ///
    /// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
    @Test(
        "--out がフォルダを指す綴り (末尾の /・. ・..) なら、名前に # や .mov があっても止まる",
        arguments: ["take#1/", "out-##/", "dir/", "motion.mov/", "take#1/.", "f-##.png/.."])
    func anOutThatNamesAFolderIsRefused(out: String) {
        expectOutRefused(out)
    }

    /// **`run` / `watch` の選択肢はそのまま効き、知らない選択肢は断る** (``Invocation`` と同じ規律)。
    @Test("知らない選択肢は、場所にせずに止まる")
    func anUnknownOptionIsRefused() {
        expectUsage(["--fps", "30", "--seconds", "2", "--out", "/a.mov", "-o", "x"], mentioning: "-o")
    }

    /// **構成の値も、組み立ての前に検める** ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。
    /// 検めずに道具立てへ渡すと、組み立てを始めてから「Package.swift に実行ファイルが無い」と
    /// 名乗っていた。
    @Test("構成は debug / release だけを受け、それ以外は受け付ける値を名指して止まる")
    func anUnknownConfigurationIsRefused() throws {
        for configuration in ["bogus", "Release", "DEBUG"] {
            expectUsage(
                ["-c", configuration, "--fps", "10", "--seconds", "0.1", "--out", "/c.mov"],
                mentioningAll: ["debug", "release", ": \(configuration)"])
        }
        for configuration in ["debug", "release"] {
            let options = try parse(
                ["-c", configuration, "--fps", "10", "--seconds", "0.1", "--out", "/c.mov"])
            #expect(options.invocation.configuration == configuration)
        }
    }

    /// 解いた後にパッケージを探すので、`Package.swift` の無い場所でも使い方の誤りが先に出る。
    @Test("引数の誤りは、スケッチを探す前 (ビルドの前) に止まる")
    func argumentErrorsComeBeforeTheBuild() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let refused = #expect(throws: CommandFailure.self) {
            try RenderCommand.run([empty.path, "--fps", "30", "--out", "/a.mov"])
        }
        guard case .usage = refused else {
            Issue.record("使い方の誤りの前に、別の理由で止まった: \(String(describing: refused))")
            return
        }
        // 引数が揃えば、次はスケッチを探して無いと言う (ここでもビルドはしない)
        #expect(throws: CommandFailure.packageNotFound(path: empty.path)) {
            try RenderCommand.run([empty.path, "--fps", "30", "--seconds", "1", "--out", "/a.mov"])
        }
    }

    @Test("案内に render の行が並ぶ")
    func theUsageListsRender() {
        let usage = Command.usage("mokume")
        #expect(usage.contains("  render [<directory>]"))
        #expect(usage.contains("--fps <n> --seconds <s> --out <path>"))
        #expect(Command.Verb.named("render") == .render)
    }

    // MARK: - 子へ渡す合図 (完了条件 8)

    /// **子は同じ型で読む。** 道具が組んだ値を、子の側の読み手がそのまま戻せること。
    @Test("書き出しの頼みは、渡したときだけ子の環境に載り、子の読み手がそのまま戻せる")
    func theRequestLandsOnlyWhenGivenAndReadsBack() throws {
        let key = StartupReads.render.key
        #expect(RunCommand.childEnvironment([:])[key] == nil)
        #expect(
            RunCommand.childEnvironment([:], reportingRate: "debug", confirmingCloseFor: "mokume run")[key]
                == nil,
            "run が渡す組み合わせで書き出しの合図が載っている")

        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 90, destination: "/tmp/a:b/out.mov"))
        let carried = RunCommand.childEnvironment([:], rendering: request)
        #expect(RenderRequest(environmentValue: try #require(carried[key])) == request)
        // 窓を持たないので、× を確かめる合図も速さの名乗りも載せない
        #expect(carried[StartupReads.closeConfirmation.key] == nil)
        #expect(carried[StartupReads.frameRateNotice.key] == nil)
    }

    // MARK: - 終わり方 (完了条件 6)

    /// 環境を書き留めてから、指定した終了コードで終わる子。
    ///
    /// - Parameter signal: 渡されたら、終了コードではなくこの合図 (`TRAP` など) で自分を落とす。
    private func makeChild(exiting status: Int32, signalled signal: String? = nil) throws
        -> (executable: URL, seen: URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seen = directory.appendingPathComponent("seen")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.render.key)" > '\(seen.path)'
            \(signal.map { "kill -s \($0) $$" } ?? "exit \(status)")
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, seen)
    }

    @Test("子が 0 で終われば何も投げず、子には頼みが渡っている")
    func aCleanChildIsQuietAndGotTheRequest() throws {
        let child = try makeChild(exiting: 0)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/out.mov"))
        try RenderCommand.launch(
            child.executable, in: child.executable.deletingLastPathComponent(), request: request)
        #expect(try String(contentsOf: child.seen, encoding: .utf8) == request.environmentValue)
    }

    /// **`render` の終了コードは「書けたか」である。** スケッチの成否として名乗ると、呼ぶ側は
    /// どこが欠けたかを読めない。
    @Test("子が 0 以外で終われば、書き出しが揃わなかったと名乗って 0 以外で終わる")
    func aFailingChildSaysTheRenderIsIncomplete() throws {
        let child = try makeChild(exiting: 1)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/out.mov"))
        #expect(
            throws: CommandFailure.renderIncomplete(
                destination: "/tmp/out.mov", ending: .exited(1))
        ) {
            try RenderCommand.launch(
                child.executable, in: child.executable.deletingLastPathComponent(),
                request: request)
        }
        let failure = CommandFailure.renderIncomplete(destination: "/tmp/out.mov", ending: .exited(1))
        #expect(failure.exitCode != 0)
        #expect(failure.message.contains("/tmp/out.mov"))
        #expect(failure.message.contains("it exited with code 1"))
    }

    /// **合図で落ちた子を「exited with code N」と名乗らない** ([#2315](https://github.com/mokume-metal/mokume/issues/2315))。
    /// `fatalError` の SIGTRAP は番号が 5 で、`terminationStatus` だけを読むと「code 5」になる。
    /// 終了コードは「書けたか」を言う値なので 1 のまま (#1282)。
    @Test("子が合図で落ちれば、合図の番号を名乗り、終了コードの形では言わない")
    func aSignalledChildIsNamedBySignal() throws {
        let child = try makeChild(exiting: 0, signalled: "TRAP")
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/out.mov"))
        let thrown = #expect(throws: CommandFailure.self) {
            try RenderCommand.launch(
                child.executable, in: child.executable.deletingLastPathComponent(),
                request: request)
        }
        #expect(
            thrown == .renderIncomplete(destination: "/tmp/out.mov", ending: .signalled(SIGTRAP)))
        let failure = try #require(thrown)
        #expect(failure.exitCode == 1)
        #expect(failure.message.contains("signal 5 (SIGTRAP)"))
        #expect(!failure.message.contains("exited with code"))
    }

    // MARK: - 書き出し先の確かめ ([#2481])

    /// 与えた本文のシェルスクリプトを走らせる子。作業ディレクトリは一時ディレクトリ。
    ///
    /// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
    private func makeScriptChild(_ body: String) throws -> (executable: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sketch")
        try "#!/bin/sh\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, directory)
    }

    /// **頼みを読まずに 0 で終わる古い子** (道具と依存の版のずれ)。何も書かない。
    /// 終了コードは 0 なので、`launch` は通る。書き出し先を見て断るのが `render`。
    @Test("頼みを読まずに 0 で終わった子は、書き出し先に何も無いと名乗って 0 以外で終わる")
    func aChildThatIgnoresTheRequestIsCaught() throws {
        let child = try makeScriptChild("exit 0")
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let movie = child.directory.appendingPathComponent("take.mov").path
        let request = try #require(RenderRequest(frameRate: 24, frameCount: 48, destination: movie))
        // 子の終わり方だけを見る口は通る — 確かめがここに無いことの確認でもある
        try RenderCommand.launch(child.executable, in: child.directory, request: request)

        let thrown = #expect(throws: CommandFailure.self) {
            try RenderCommand.render(child.executable, in: child.directory, request: request)
        }
        #expect(
            thrown == .renderOutputShort(destination: movie, expected: 48, shortfall: .notWritten))
        let failure = try #require(thrown)
        #expect(failure.exitCode != 0)
        #expect(failure.message.contains(movie))
        #expect(failure.message.contains("nothing was written"))
        // 道具は「書けた」と名乗る行を出さない — 名乗る側 (`run`) は `render` が戻った後でだけ出す
        #expect(!failure.message.contains("Wrote"))
    }

    /// 連番は「N 枚中 M 枚」を名乗る。
    @Test("連番が足りなければ、頼んだ枚数と揃った枚数を名乗って 0 以外で終わる")
    func aSeriesThatFallsShortNamesTheCounts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 4 枚頼まれて 2 枚だけ書き、0 で終わる子
        let child = try makeScriptChild(
            "printf x > '\(directory.path)/f-0.png'; printf x > '\(directory.path)/f-1.png'")
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let destination = directory.appendingPathComponent("f-#.png").path
        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 4, destination: destination))

        let thrown = #expect(throws: CommandFailure.self) {
            try RenderCommand.render(child.executable, in: child.directory, request: request)
        }
        #expect(
            thrown
                == .renderOutputShort(
                    destination: destination, expected: 4, shortfall: .frames(found: 2)))
        let failure = try #require(thrown)
        #expect(failure.exitCode != 0)
        #expect(failure.message.contains("only 2 of 4 frames"))
    }

    @Test("頼んだ枚数がこの回に書かれていれば、何も投げない")
    func aChildThatWroteEverythingPasses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-done-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = (0..<3).map { "printf x > '\(directory.path)/f-\($0).png'" }
        let child = try makeScriptChild(writes.joined(separator: "; "))
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let request = try #require(
            RenderRequest(
                frameRate: 30, frameCount: 3,
                destination: directory.appendingPathComponent("f-#.png").path))
        try RenderCommand.render(child.executable, in: child.directory, request: request)
    }

    /// **前の回の残りで通さない。** 同じ行き先へ撮り直す回に、古い子が何も書かずに終わっても、
    /// 前の回の連番が揃って見えてはならない。
    @Test("前の回の連番が残っているだけなら、この回は書けていないと名乗る")
    func leftoversFromAnEarlierRunDoNotPass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-left-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 0..<3 {
            let file = directory.appendingPathComponent("f-\(number).png")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        }
        let child = try makeScriptChild("exit 0")
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let destination = directory.appendingPathComponent("f-#.png").path
        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 3, destination: destination))
        #expect(
            throws: CommandFailure.renderOutputShort(
                destination: destination, expected: 3, shortfall: .frames(found: 0))
        ) {
            try RenderCommand.render(child.executable, in: child.directory, request: request)
        }
    }

    /// 子が 0 以外で終わった回は、書き出し先を見る前に子の失敗として断る (子が理由を名乗っている)。
    @Test("子が 0 以外で終わった回は、これまでどおり書き出しが揃わなかったと名乗る")
    func aFailingChildIsStillIncomplete() throws {
        let child = try makeScriptChild("exit 1")
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/mokume-never.mov"))
        #expect(
            throws: CommandFailure.renderIncomplete(
                destination: "/tmp/mokume-never.mov", ending: .exited(1))
        ) {
            try RenderCommand.render(child.executable, in: child.directory, request: request)
        }
    }

    // MARK: - 途中で止める (完了条件 7)

    /// **端末の Control + C は子へ届かない** — `Process` は子を別のプロセスグループに置くので、
    /// 前面のグループ (道具) にしか配られない。道具が受けて渡さないと、道具だけが消えて子は
    /// 書き出しを続ける。ここでは検査の走者を道具に見立て、**自分のプロセスへ** SIGINT を送る。
    ///
    /// **壊れた実装で走者ごと死なせない。** 受け口が置かれていなければ送らずに失敗を記録する。
    @Test("道具へ SIGINT が届いたら子を止め、止めたと名乗る")
    func aSigintToTheToolStopsTheChild() throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Sender: @unchecked Sendable {
            var failures: [String] = []
            var pid: pid_t?
            let done = DispatchSemaphore(value: 0)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-sigint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            echo $$ > '\(marker.path).tmp' && mv '\(marker.path).tmp' '\(marker.path)'
            exec sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // **既定の受け口から始める。** 走者が無視で継いでいると、SIGINT を受けない側へ倒れる
        let kept = SignalState.current()
        defer { kept.restore() }
        signal(SIGINT, SIG_DFL)

        let sender = Sender()
        Thread.detachNewThread {
            defer { sender.done.signal() }
            let deadline = DispatchTime.now() + 30
            while DispatchTime.now() < deadline {
                if let text = try? String(contentsOf: marker, encoding: .utf8),
                    let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    sender.pid = pid
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pid = sender.pid else {
                sender.failures.append("子が起きない")
                return
            }
            var current = sigaction()
            sigaction(SIGINT, nil, &current)
            guard current.__sigaction_u.__sa_handler != nil else {
                sender.failures.append("書き出している間、SIGINT の受け口が置かれていない")
                kill(pid, SIGKILL)
                return
            }
            kill(getpid(), SIGINT)
            let gone = DispatchTime.now() + 10
            while kill(pid, 0) == 0, DispatchTime.now() < gone {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if kill(pid, 0) == 0 {
                sender.failures.append("道具が SIGINT を受けたのに、子が残っている")
                kill(pid, SIGKILL)
            }
        }

        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 900, destination: "/tmp/stopped.mov"))
        #expect(throws: CommandFailure.stopped(signal: SIGINT)) {
            try RenderCommand.launch(executable, in: directory, request: request)
        }
        #expect(sender.done.wait(timeout: .now() + 60) == .success, "合図を送る糸が戻らない")
        for failure in sender.failures { Issue.record(Comment(rawValue: failure)) }
        let pid = try #require(sender.pid)
        #expect(kill(pid, 0) != 0, "launch が戻った後も子が残っている")
        var after = sigaction()
        sigaction(SIGINT, nil, &after)
        #expect(after.__sigaction_u.__sa_handler == nil, "走り終えた後に、SIGINT の受け口を元へ戻していない")
    }

    @Test("書き終えたら、どこへ何枚書いたかを 1 行で名乗る")
    func theReportNamesTheCountAndThePlace() throws {
        let request = try #require(
            RenderRequest(frameRate: 60, frameCount: 2880, destination: "/tmp/cast.mov"))
        let line = RenderCommand.report(request)
        #expect(line == "Wrote 2880 frames at 60 fps to /tmp/cast.mov")
        #expect(!line.contains("\n"))
    }
}
