// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// ひな形から作ったものが、実際に組み上がるか。
///
/// **形を見るだけでは足りない。** ひな形の Swift が壊れていても、鍵の差し込みや
/// ファイルの並びを見る検査は緑のまま通る — 壊れたひな形が配られるのはそこである。
/// 実際に組み上げるので時間がかかるが、ここを省くと「作った人だけが気付く」形になる。
@Suite("ひな形から作ったものが組み上がる")
struct TemplateBuildTests {
    /// このリポジトリの場所。作ったスケッチはここをパスで指す (まだ版が出ていない
    /// 段階でも組み上げられるように)。
    static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
    }

    @Test("作ったスケッチが、そのまま組み上がる")
    func theGeneratedSketchBuilds() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let options = NewCommand.Options(
            name: "try-sketch", path: workspace.path, local: Self.repository.path)
        let root = workspace.appendingPathComponent("try-sketch", isDirectory: true)
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let built = try BuildProcess.build(in: root)
        #expect(built.killed == false, "組み上げが終わらないまま期限に達した")
        #expect(built.status == 0, "ひな形から作ったものが組み上がらない:\n\(built.output)")
    }

    @Test("置いた資材が、絵を探す場所へ運ばれる")
    func assetsLandWhereImagesAreLookedFor() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let options = NewCommand.Options(
            name: "asset-sketch", path: workspace.path, local: Self.repository.path)
        let root = workspace.appendingPathComponent("asset-sketch", isDirectory: true)
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        // 作った直後のスケッチへ、資材を 1 つ置く
        let asset = root.appendingPathComponent(
            "Sources/asset-sketch/assets/grain.txt")
        try "木目".write(to: asset, atomically: true, encoding: .utf8)

        // 宣言があるので、走らせる前の検査は通る
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }

        let built = try BuildProcess.build(in: root)
        #expect(built.killed == false, "組み上げが終わらないまま期限に達した")
        #expect(built.status == 0, "資材を置いたスケッチが組み上がらない:\n\(built.output)")

        // 実行ファイルの隣を起点に、絵を探す並びの中に運ばれた資材が入っている。
        // **ここが繋がっていないと、宣言は書かれているのに実行時に読めない**
        let executable = try RunCommand.executablePath(in: root)
        let neighbourhood = executable.deletingLastPathComponent()
        let searched = ImageFile.candidates(
            for: "assets/grain.txt", workingDirectory: root.path,
            neighbourhood: neighbourhood, resources: nil)
        let found = searched.first { FileManager.default.fileExists(atPath: $0.path) }
        #expect(
            found != nil,
            """
            置いた資材が、絵を探す場所のどこにも運ばれていない。
            探した場所:
            \(searched.map { "  - \($0.path)" }.joined(separator: "\n"))
            """)
    }

    /// 束ねた包みの中で、同じことが成り立つか。
    ///
    /// **配ったときにしか通らない経路がある。** 包みの中では実行ファイルの隣が
    /// `Contents/MacOS/` になり、資材は `Contents/Resources/` へ入る。組み上げの
    /// 隣だけを見ていると、手元では動いて配った先だけで絵が出ない形になる。
    ///
    /// **ここだけ期限を持てない。** 組み上げるのは `BundleCommand.run` の中で、期限を
    /// 置くとしたら製品のコードになる — 利用者の `mokume bundle` が時計で殺される形は
    /// 採らない。外した `.timeLimit` はもともと効いていなかった (同期の本体が main actor
    /// を塞ぐので、上限が鳴ってもプロセスは終わらない) ので、失うものは無い (#564)。
    @Test("束ねた包みの中でも、資材が絵を探す場所にある")
    func assetsLandInsideTheBundledApplication() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-bundled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let options = NewCommand.Options(
            name: "packed-sketch", path: workspace.path, local: Self.repository.path)
        let root = workspace.appendingPathComponent("packed-sketch", isDirectory: true)
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try "木目".write(
            to: root.appendingPathComponent("Sources/packed-sketch/assets/mark.txt"),
            atomically: true, encoding: .utf8)
        try AppIdentity.example.write(
            to: root.appendingPathComponent(AppIdentity.fileName), atomically: true,
            encoding: .utf8)

        try BundleCommand.run([root.path])

        let app = root.appendingPathComponent("bundle/Grain.app", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: app.path), "包みが出来ていない")

        // 開き方は包みの**隣**に出る。中にあっては、開けない人には読めない
        let note = root.appendingPathComponent("bundle/Grain を開くには.txt")
        #expect(
            FileManager.default.fileExists(atPath: note.path),
            "開き方の紙が包みの隣に無い。作品と一緒に送れる物になっていない")

        // 与えた名前が codesign へ**届いている**こと。本物の証明書はこの環境に無いので、
        // 確かめられるのはここまで — 鍵束に無い名前なら止まる
        #expect(throws: (any Error).self) {
            try BundleCommand.sign(app, as: "mokume の検査が与えた、鍵束に無い名前")
        }

        // 包みの中だけを起点にする。**組み上げた場所は見せない** — そこが見えていると、
        // 配った先で足りているかを確かめたことにならない
        let searched = ImageFile.candidates(
            for: "assets/mark.txt", workingDirectory: "/", neighbourhood: app,
            resources: app.appendingPathComponent("Contents/Resources", isDirectory: true))
        let found = searched.first { FileManager.default.fileExists(atPath: $0.path) }
        #expect(
            found != nil,
            """
            束ねた包みの中に、置いた資材が入っていない。
            探した場所:
            \(searched.map { "  - \($0.path)" }.joined(separator: "\n"))
            """)

        // 描くのに要る断片も、同じ包みの中から見つかる
        let shader = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: app,
            resources: app.appendingPathComponent("Contents/Resources", isDirectory: true),
            lastResort: { _, _ in nil })
        #expect(shader != nil, "描くのに要る断片が包みの中に無い")
    }
}

/// 組み上げのプロセスを、**期限つきで**待つ。
///
/// **止め木を待つ側に置く理由。** `.timeLimit` はこのパッケージでは使えない — 上限は
/// 検査の走り出しからの時計で測られ、検査はすべて main actor に載っているので、どんな
/// 値を書いても「検査**全体**が何秒で終わるか」を要求することになる ([#564])。実測では
/// 905 件のうち 875 件が「60 秒超」を報告した。
///
/// **型ごと `nonisolated` にする。** `Package.swift` の `.defaultIsolation(MainActor.self)`
/// はこのパッケージ全体に効くので、既定のままだと期限を数える閉包まで main actor 隔離と
/// 推論され、別の走りで鳴った瞬間に `dispatch_assert_queue` で落ちる (実測: SIGTRAP で
/// 検査バンドルごと死ぬ)。期限は main actor の外で数えなければ意味が無い。
///
/// [#564]: https://github.com/mokume-metal/mokume/issues/564
nonisolated enum BuildProcess {
    /// 既定の期限。組み上げは資材の取得から始まることもあるので長めに取るが、
    /// **止め木であって速さの主張ではない**。
    static let limit: Double = 600

    /// 期限を越えたら殺す係。
    ///
    /// **`Process` は `Sendable` ではない**が、期限を数えるのは別の走りでなければ
    /// ならない (main actor は `waitUntilExit()` で塞がっている)。殺す 1 手と殺した
    /// かの印だけをここへ閉じて渡す — `terminate()` は別の走りから呼んでよい。
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var killed = false
        init(_ process: Process) { self.process = process }
        var didKill: Bool { lock.withLock { killed } }
        func kill() {
            lock.withLock { killed = true }
            process.terminate()
        }
    }

    /// 走らせて待つ。**越えたら殺す。**
    ///
    /// 報告するだけでは足りない。`waitUntilExit()` は main actor を塞いだまま止まる
    /// ので、殺さなければ後続の検査が 1 つも進まないまま run 全体が固まる。
    static func run(
        _ process: Process, reading pipe: Pipe, within seconds: Double = limit
    ) throws -> (status: Int32, output: String, killed: Bool) {
        try process.run()
        let deadline = Deadline(process)
        let alarm = DispatchWorkItem { deadline.kill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: alarm)
        defer { alarm.cancel() }

        // **読み切ってから待つ。** 逆順にすると、出力が管を埋めた時点で子が書けなく
        // なって止まる
        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output, deadline.didKill)
    }

    /// `swift build` を、期限つきで。
    static func build(in directory: URL) throws -> (status: Int32, output: String, killed: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build"]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return try run(process, reading: pipe)
    }
}

/// 止め木そのものの検査。
///
/// **効くことを見ていない止め木は、止め木ではない。** 待ち続けるだけのヘルパを書いても、
/// 組み上げが終わるうちは緑のまま通る — 効いていないと分かるのは本当に固まった日で、
/// そのとき run は何も出さずに固まる。
@Suite("組み上げの待ちには期限がある")
struct BuildDeadlineTests {
    /// **待たせる側は有限にする。** 永遠に眠る相手にすると、止め木が効かなくなった
    /// 日にこの検査は赤くならず**固まる** — 壊れたことを知らせる手立てを、壊れ方の
    /// 巻き添えにしないため。20 秒眠る相手を 0.5 秒で殺すので、効いていなければ
    /// 20 秒後に赤く落ちる。
    @Test("終わらないプロセスは、期限で殺される")
    func aProcessThatOutlivesTheDeadlineIsKilled() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let started = Date()
        let result = try BuildProcess.run(process, reading: pipe, within: 0.5)
        let waited = Date().timeIntervalSince(started)

        #expect(result.killed, "期限を越えたのに殺されていない")
        #expect(result.status != 0, "殺されたのに、終わり方が成功を名乗っている")
        #expect(waited < 10, "期限を 0.5 秒にしたのに \(waited) 秒待っている")
    }

    @Test("期限の内に終わるプロセスは、殺されずそのまま返る")
    func aProcessThatEndsInTimeIsNotKilled() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["木目"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let result = try BuildProcess.run(process, reading: pipe, within: 60)

        #expect(result.killed == false, "期限の内に終わったのに殺された")
        #expect(result.status == 0)
        #expect(result.output.contains("木目"), "出力が読み取れていない")
    }
}
