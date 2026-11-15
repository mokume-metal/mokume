// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 実行を頭から終わりまで 1 本の記録にする頼み (`mokume run --record <path>`・[#3570])。
///
/// ## 誰が決めるか
///
/// **道具が決め、環境変数で子へ渡す** (``StartupReads/record``・`MOKUME_RENDER` と同じ形)。作品のコードは
/// 1 行も変えない。値は記録の行き先のファイルの**絶対パス**そのもの — 相対の値は読む側の作業ディレクトリで
/// 別の場所になる (子は作業ディレクトリをスケッチに替えて起こされる)。道具が走らせた場所から解いて渡す。
///
/// ## 行き先は旗が必ず指す
///
/// 既定の行き先は持たない (2026-10-31 の決定)。`watch` は世代ごとに別の行き先を渡す
/// (``generation(of:number:)``)。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
package nonisolated struct ReplayRequest: Equatable, Sendable {
    /// 記録の行き先 (ファイル)。**絶対パス。**
    package let destination: URL

    /// 行き先を指して頼む。絶対パスでなければ作れない。
    ///
    /// **前後の空白や改行は削らない。** 道具が「Recording to:」と言った綴りと、子が書く場所が食い違う (空白の
    /// 付いた名前のファイルは作れる)。空・`/` だけ・絶対パスでない値だけを断る。
    package init?(destination path: String) {
        guard path.hasPrefix("/"), path.count > 1 else { return nil }
        self.destination = URL(fileURLWithPath: path)
    }

    /// 環境変数に載せる値。
    package var environmentValue: String { destination.path }

    /// `watch` の世代 `number` (1 から) の行き先。**拡張子の前に `-<番号>` を挟む** (`take.json` → `take-2.json`)。
    /// 拡張子が無ければ末尾に付ける。作り直しは記録の切れ目なので、世代ごとに別のファイルになる。
    package static func generation(of destination: String, number: Int) -> String {
        let url = URL(fileURLWithPath: destination)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let numbered = ext.isEmpty ? "\(name)-\(number)" : "\(name)-\(number).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(numbered).path
    }

    /// `watch` の次の世代を、`number` の次の番号から選ぶ ([#3970])。
    ///
    /// **世代の名前は道具が作ったもので、利用者は名指していない** (`run --record` の行き先とは違う)。その名前に
    /// 記録でないもの (記録の頭で始まらない通常ファイル・フォルダ・シンボリックリンクなど) が在れば、子が行き先として
    /// 置き換えないように**番号を飛ばし**、何も無いか記録の残りが在る番号を選ぶ。飛ばした名前は呼ぶ側が知らせる。
    ///
    /// [#3970]: https://github.com/mokume-metal/mokume/issues/3970
    ///
    /// - Parameter destination: `--record` で頼まれた行き先 (絶対パス)。
    /// - Parameter number: 前の世代の番号 (始まりは 0)。
    /// - Returns: 選んだ番号と、飛ばした番号を塞いでいた名前 (番号の順。行き先 `take-1.json` か、錠の名前
    ///   `take-1.json.lock` のどちらか実際に塞いでいたもの)。
    package static func nextGeneration(of destination: String, after number: Int) -> (number: Int, skipped: [String]) {
        var candidate = number + 1
        var skipped: [String] = []
        while true {
            let path = generation(of: destination, number: candidate)
            guard let blocking = blockingName(of: path) else { return (candidate, skipped) }
            skipped.append(URL(fileURLWithPath: blocking).lastPathComponent)
            candidate += 1
        }
    }

    /// 世代の行き先を塞いでいる名前。使えれば `nil`。使えるのは、行き先が何も無いか記録 (``isRecordFile(_:)``) で、
    /// **錠の名前 (`<行き先>.lock`) も何も無いか通常ファイル**のもの。錠の名前にリンク・フォルダなどが在ると、子は錠を
    /// 取れずにその世代を記録しない (``ReplayClaim/take(destination:)``) ので、その番号も飛ばす。
    ///
    /// 見られない名前 (親がファイル・権限が無い) は空きとして返す — どの番号でも同じなので、飛ばし続けずに子に
    /// 渡し、子が書けない理由を言う。
    private static func blockingName(of path: String) -> String? {
        var status = stat()
        if lstat(path, &status) == 0, !isRecordFile(path) { return path }
        let lock = path + ReplayClaim.lockSuffix
        guard lstat(lock, &status) == 0 else { return nil }
        return (status.st_mode & S_IFMT) == S_IFREG ? nil : lock
    }

    /// 記録の頭 (`{"schemaVersion":`) で始まる**通常ファイル**か。**リンクはたどらず、通常ファイルでないもの (フォルダ・
    /// FIFO など) は開かない** — FIFO を読みに開くと、書き手が来るまで止まる (#3970)。世代の番号を選ぶ側
    /// (``nextGeneration(of:after:)``) と、前の見張りの世代を消す側 (``discardGenerations(of:)``) が、同じこの判定を使う。
    static func isRecordFile(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return false }
        // 通常ファイルは 1 度の read で頭の 32 バイト (短ければ全部) が返る
        var head = [UInt8](repeating: 0, count: 32)
        let count = head.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return false }
        return head[..<count].starts(with: Array("{\"schemaVersion\":".utf8))
    }

    /// 起動の口。**記録しない実行 (ホストのアプリの中の ``SketchView``・書き出しの子) でも、合図は読まずに環境
    /// から消す** — 残れば、そこから起こす子 (孫) が継いで、頼んでいない実行が記録を始める。
    ///
    /// - Parameter records: この実行が記録を頼まれうるか。偽なら読まず、理由も言わない。
    package static func startup(
        forRun records: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) },
        say: (String) -> Void = { Diagnostics.warn($0) }
    ) -> ReplayRequest? {
        guard records else {
            unset(StartupReads.record.key)
            return nil
        }
        return startup(environment: environment, unset: unset, say: say)
    }

    /// 起動の環境から読む。**無ければ `nil`。** 読んだら環境から消す (``ClockHandover/startup(environment:unset:)``
    /// と同じ) — 合図はこのプロセスを起こした道具が渡したもので、このプロセスがさらに起こす子のものではない。
    ///
    /// 在って読めない値 (相対パス・空) は、`nil` を返して理由を 1 度言う。**環境を読むのはここだけ** — 一覧
    /// (``StartupReads``) が読み場所としてこのファイルを名指している。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) },
        say: (String) -> Void = { Diagnostics.warn($0) }
    ) -> ReplayRequest? {
        guard let given = environment[StartupReads.record.key] else { return nil }
        unset(StartupReads.record.key)
        guard let request = ReplayRequest(destination: given) else {
            say(
                "Not recording: \(StartupReads.record.key) is not the absolute path of a file (\(given)). "
                    + "Pass the destination with --record <path> to mokume run or mokume watch")
            return nil
        }
        return request
    }

    // MARK: - watch の世代

    /// `watch` が始まるとき、前の見張りが残した同じ並び (`<stem>-<N>.<ext>`) の記録と `.partial` を消す。
    /// **1 から振り直すので、残しておくと前回の `take-3` が今回の `take-1`・`take-2` と混ざる** (`run` が前回の
    /// 完成品を消すのと同じ扱い)。
    ///
    /// 消すのは、**記録の頭 (`{"schemaVersion":`) で始まる通常ファイルの完成品** (``isRecordFile(_:)``。リンク・
    /// フォルダ・FIFO は残す) と、``ReplayClaim`` の名前の形の `.partial` だけ
    /// — 同じ並びの名前の、記録でないファイルにも、`.partial` の名前のフォルダ (``AtomicFile/remove(_:)``・#3943)
    /// にも触らない。世代ごとの錠を取れない行き先 (今、別の実行が書いている)
    /// も飛ばす。
    ///
    /// - Parameter destination: `--record` で頼まれた行き先 (絶対パス)。
    /// - Returns: 消したファイルの名前。
    @discardableResult
    package static func discardGenerations(of destination: String) -> [String] {
        let url = URL(fileURLWithPath: destination)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        var names: Set<String> = []
        for entry in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            if let name = generationName(of: entry, stem: stem, suffix: suffix) { names.insert(name) }
        }
        var removed: [String] = []
        for name in names.sorted() {
            let target = directory.appendingPathComponent(name)
            guard let claim = ReplayClaim.take(destination: target).claim else { continue }
            defer { claim.release() }
            // 見てから消すまでの間にフォルダへ替わっても消さない (``AtomicFile/remove(_:)``・#3943)
            // リンク・フォルダ・FIFO は記録でないものとして残す (番号を選ぶ側と同じ判定・#3970)
            if isRecordFile(target.path), AtomicFile.remove(target) {
                removed.append(name)
            }
            for entry in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            where ReplayClaim.isPartial(entry, of: name) {
                if AtomicFile.remove(directory.appendingPathComponent(entry)) { removed.append(entry) }
            }
        }
        return removed
    }

    /// 世代のファイルの名前 (`take-3.json`) か、その `.partial` (`take-3.json.1234.partial`) なら、世代の名前。
    private static func generationName(of entry: String, stem: String, suffix: String) -> String? {
        let prefix = stem + "-"
        guard entry.hasPrefix(prefix) else { return nil }
        let rest = entry.dropFirst(prefix.count)
        let digits = rest.prefix { ("0"..."9").contains($0) }
        guard !digits.isEmpty else { return nil }
        let name = prefix + String(digits) + suffix
        if entry == name || ReplayClaim.isPartial(entry, of: name) { return name }
        return nil
    }
}
