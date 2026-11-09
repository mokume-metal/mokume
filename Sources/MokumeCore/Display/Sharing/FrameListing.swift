// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 名乗った送り手の目録 ([ADR-0049] 決定 3・5)。
///
/// 利用者ごとの決まった置き場に、送り手 1 つにつき 1 ファイルを置く。受け手は置き場を読み、項目の
/// bootstrap の名前を `bootstrap_look_up` で引けたものだけを生きているとみなす。受け手は読むだけで、書かない。
///
/// ## 置き場
///
/// **`~/Library/Application Support/mokume/frames/`** (利用者だけが書ける。共有の `/tmp` にしない)。
/// `$TMPDIR` は採らない — OS が 3 日触られていないファイルを掃除するので、長く走る展示の項目が消える。
///
/// ## 受け手が変化を知る方法
///
/// **置き場のディレクトリを見張る** (kqueue の `NOTE_WRITE`)。項目は一時ファイルからの置き換え
/// (``AtomicFile``) で置き、消すときは unlink するので、増えても減ってもディレクトリの項目が変わり、
/// 必ず知らせが立つ。時計は使わない。
///
/// ## 死んだ項目の掃除
///
/// **次に名乗る送り手が消す** (``sweep(in:)``)。消すのは pid のプロセスが居ない項目と、pid は居るが
/// 起動の時刻が違う (pid が使い回された) 項目だけである。`bootstrap_look_up` が通らないだけでは消さない
/// — 別の名前空間 (ssh や別のログインのセッション) から名乗った送り手は、生きていても引けない。
///
/// ## 検査の中では手元の目録に書かない
///
/// 本体の検査がウィンドウを開くたびに、開発者の受け手の一覧に検査のスケッチが並ぶのを避ける。自分か
/// 祖先のプロセスが mokume の検査 (``SelfTest``) なら、その検査のプロセスごとの一時の置き場を使う
/// (``directory(forTestRun:)``)。検査が起こした子 (参照のスケッチ) や孫 (検査が起こした道具の子) も
/// 同じ置き場に揃うので、本体の中の受け手 (#3922) はそこを引けばよい。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
package nonisolated enum FrameListing {
    /// 約束の版。上げ方は ADR-0018 決定 5。
    static let schemaVersion = 1

    /// いまのウィンドウは常に 1 つなので、ウィンドウの欄は固定値 ([ADR-0049] 決定 5)。
    static let mainWindow = "main"

    /// 目録の 1 件。
    package struct Entry: Codable, Equatable, Sendable {
        /// 約束の版。
        package var schemaVersion: Int = FrameListing.schemaVersion
        /// 作品名。SwiftPM の product の名前 (実行ファイルの名前)。`.app` でもこの名前のまま。
        package var sketch: String
        /// ウィンドウ。作品名とは別の欄。
        package var window: String = FrameListing.mainWindow
        /// 作品を見分ける欄。`.app` なら bundle identifier、直に走らせるならパッケージの場所。
        package var identity: String
        /// 一覧に見せる名前 (`SketchSettings.title`)。**識別には使わない。**
        package var title: String
        /// 名乗ったプロセス。`watch` では道具。
        package var pid: Int32
        /// そのプロセスの起動の時刻 (1970 年からのマイクロ秒)。pid の使い回しを見分ける。
        package var startedAt: Int64
        /// `bootstrap_look_up` で引く名前。
        package var serviceName: String
    }

    /// 置き場。
    static var directory: URL { resolvedDirectory }

    private static let resolvedDirectory: URL = {
        if let testRun = testRun() { return directory(forTestRun: testRun) }
        return userDirectory
    }()

    /// 手元の (利用者の) 置き場。
    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/mokume/frames", isDirectory: true)
    }

    /// 検査のプロセスごとの置き場。
    static func directory(forTestRun pid: pid_t) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-frames-test-\(pid)", isDirectory: true)
    }

    /// 自分か祖先のうち、mokume の検査のプロセスの pid。**検査の中でなければ `nil`。**
    ///
    /// 祖先を辿るのは、検査が起こした子や孫 (別のプロセス) も検査の置き場へ寄せるためである。
    static func testRun(
        from pid: pid_t = getpid(),
        arguments: (pid_t) -> [String] = ProcessRecord.arguments(of:),
        parent: (pid_t) -> pid_t? = ProcessRecord.parent(of:)
    ) -> pid_t? {
        var current = pid
        // 祖先は数段で launchd (1) に着く。輪になった答えでも止まるよう、段数に上限を持つ
        for _ in 0..<16 {
            if SelfTest.isRunning(arguments: arguments(current)) { return current }
            guard let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }

    /// パッケージの場所から、作品を見分ける欄を作る。**シンボリックリンクを解いた形にそろえる** — `mokume run` の子は
    /// 作業の場所を解いた形 (`/private/tmp/…`) で知り、`watch` の道具は渡された形 (`/tmp/…`) で知るので、そろえないと
    /// 同じ作品が起こし方で別の作品に見え、受け手の自動の繋ぎ直し ([ADR-0049] 決定 3) が外れる。
    ///
    /// 解くのは `realpath(3)` で、Foundation の `resolvingSymlinksInPath()` は使わない — あちらは `/private` を剥がし、
    /// 在る場所でも `/tmp` の形に寄せる。解けない (在らない) 場所は、整えた形のまま返す。
    package static func identity(ofPackageAt url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 項目のファイル。
    static func url(for serviceName: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(serviceName).json")
    }

    /// 項目を原子的に置く。置き場が無ければ利用者だけが入れる権限で作る。
    @MainActor static func place(_ entry: Entry, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(encoder.encode(entry), to: url(for: entry.serviceName, in: directory))
    }

    /// 項目を消す。無ければ何もしない。
    static func remove(_ serviceName: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(for: serviceName, in: directory))
    }

    /// 置き場の項目を読む。読めない項目は飛ばす。
    static func entries(in directory: URL) -> [Entry] {
        files(in: directory).compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }
    }

    /// 死んだ項目を消す。消した項目の名前を返す。
    ///
    /// **読めない項目は消さない** (新しい版の項目かもしれない)。pid と起動の時刻だけを読むので、
    /// 他の欄が増えた新しい版の項目も判定できる。
    @discardableResult
    static func sweep(
        in directory: URL,
        isAlive: (pid_t) -> Bool = ProcessRecord.isAlive(_:),
        startTime: (pid_t) -> Int64? = ProcessRecord.startTime(of:)
    ) -> [String] {
        struct Liveness: Decodable {
            var pid: Int32
            var startedAt: Int64
        }
        var removed: [String] = []
        for url in files(in: directory) {
            guard let data = try? Data(contentsOf: url),
                let entry = try? JSONDecoder().decode(Liveness.self, from: data)
            else { continue }
            let dead = !isAlive(entry.pid) || startTime(entry.pid).map { $0 != entry.startedAt } == true
            guard dead else { continue }
            try? FileManager.default.removeItem(at: url)
            removed.append(url.deletingPathExtension().lastPathComponent)
        }
        return removed
    }

    /// 置き場の項目のファイル。点で始まるもの (書きかけの一時ファイル) は含めない。
    private static func files(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
    }
}
