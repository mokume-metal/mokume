// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// **検査が一時の場所に作った区画の持ち主** (#3298)。
///
/// 検査が `FileManager.default.temporaryDirectory` の下へ自分で作った区画は、作った検査が片付ける。
/// 製品は利用者の区画を消す持ち主ではなく、片付けない検査の区画は一時の場所に積もり続ける —
/// 手元の共有の一時の場所に 6 万を越える `mokume-*` が残り、その全体を走査する検査 (起動時の
/// 古い観測の写しの回収) まで遅くした。
///
/// 作った区画をここへ登録し、持ち主が終わるときに消す。**検査の成功にも throw にも依らない** —
/// 検査の本体に `defer` を並べる形だと、区画を返す補助の呼び手ごとに書き漏らす。
/// 実体は ``TestScratch`` (プロセスの終わりに消す) が 1 つ持つ。この型を別に作れば、他の検査の
/// 区画を巻き込まずに、登録と後始末だけを単体で確かめられる。
public nonisolated final class ScratchOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var owned: [URL] = []
    /// 区画を作る親。既定は一時の場所。
    public let base: URL

    public init(base: URL = FileManager.default.temporaryDirectory) {
        self.base = base
    }

    /// 持ち主が消す項目の数。
    public var count: Int { lock.withLock { owned.count } }

    /// `<prefix>-<UUID>` の名前の、空の区画を作る。
    ///
    /// 名前は ``path(_:pathExtension:isDirectory:)`` と同じ形で、親の直下に作る (親から相対で辿る
    /// 検査の前提を変えない)。
    public func directory(_ prefix: String) throws -> URL {
        let url = path(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 作らずに、持ち主へ登録だけした `<prefix>-<UUID>[.<pathExtension>]` の場所を返す。
    ///
    /// 検査がこの場所へ書く (ファイルでも区画でもよい)。書かないままでも後始末は構わない。
    public func path(_ prefix: String, pathExtension: String? = nil, isDirectory: Bool = false) -> URL {
        var url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: isDirectory)
        if let pathExtension, !pathExtension.isEmpty {
            url = url.appendingPathExtension(pathExtension)
        }
        adopt(url)
        return url
    }

    /// 呼び手が名前を決める場所 (`base/<name>`) を、持ち主へ登録して返す (作らない)。
    ///
    /// 名前に一意な部分 (UUID・pid など) を含めるのは呼び手の責任。他の検査やセッションと
    /// 同じ名前を分け持つと、片方の後始末がもう片方の区画を消す。
    public func path(named name: String, isDirectory: Bool = false) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: isDirectory)
        adopt(url)
        return url
    }

    /// 検査が別の方法で作った場所を、持ち主へ預ける。
    public func adopt(_ url: URL) {
        lock.withLock { owned.append(url) }
    }

    /// 預かったものを全部消す。
    ///
    /// 書き込み権を落とした区画 (検査が 0o500 にしている間に殺された区画など) は、権限を戻して 1 度
    /// やり直す (``ScratchRemoval``)。
    ///
    /// - Returns: 消せなかった場所 (親が書けないなど)。1 つが消せなくても残りは消し続ける。
    @discardableResult
    public func removeAll() -> [URL] {
        let urls = lock.withLock {
            let urls = owned
            owned = []
            return urls
        }
        var failed: [URL] = []
        for url in urls {
            // 検査が既に消した (自分で `defer` した) 場所は在らないので、失敗ではない。
            // **在るかは `lstat` 相当で見る** — `fileExists` はぶら下がった symlink を「無い」と読んで、
            // symlink そのものを残す
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { continue }
            if !ScratchRemoval.remove(url) { failed.append(url) }
        }
        return failed
    }
}

/// 区画を消す。**消せなければ、辿った分の書き込み権を戻して 1 度だけやり直す。**
///
/// 検査が区画を 0o500 などにしている間にプロセスが殺されると、区画が消せないまま残り、親の掃除が
/// 毎回失敗して黙って残り続ける。権限を戻すのは区画とその中のディレクトリだけで、**symlink は辿らない**
/// (`setAttributes` は symlink の指す先を変える)。区画の親の権限は触らない。
public nonisolated enum ScratchRemoval {
    /// - Returns: 消せたか (最初から無ければ失敗)。
    public static func remove(_ url: URL) -> Bool {
        if (try? FileManager.default.removeItem(at: url)) != nil { return true }
        restoreWriteAccess(url)
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    private static func restoreWriteAccess(_ url: URL) {
        let fileManager = FileManager.default
        // `attributesOfItem` は `lstat` 相当で、symlink は `.typeSymbolicLink` と読む
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else { return }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        try? fileManager.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: url.path)
        for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] {
            restoreWriteAccess(url.appendingPathComponent(name))
        }
    }
}

/// 持ち主の居ない古い検査の親を掃く (``TestScratch`` が最初の使用で 1 度だけ呼ぶ)。
///
/// 製品の `ObservationCopies.sweepStale` と同じ作法 — 名前の `<pid>` が、いま走っていない
/// プロセスのものだけを消す。**自分の親と、走っている検査の親は触らない。** pid の再利用で消し
/// 損ねることはあっても、生きている検査の親は消さない向きに倒す。製品の型は `MokumeCLI` の
/// internal で、この target は Foundation だけに依るので、生死の判定は同じ式を写している。
/// 接頭辞が違うもの (製品の置き場・他の検査の区画・既に積もった `mokume-*`) と、
/// `mokume-test-<pid>-<UUID>` の形に厳密に合わない名前 (``ownerPid(ofName:)``) には触れない。
/// 消せない区画は、書き込み権を戻して 1 度やり直す (``ScratchRemoval``)。
public nonisolated enum ScratchSweep {
    /// 検査の親の名前の頭。続く `<pid>-<uuid>` の pid が持ち主。
    public static let prefix = "mokume-test-"

    /// pid のプロセスが居るか。
    public static let processExists: @Sendable (pid_t) -> Bool = { pid in
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 検査の親の名前 `mokume-test-<10 進の数字のみ>-<UUID>` から、持ち主の pid を取り出す。
    ///
    /// **形が厳密に合うものだけ**を読む。符号つき (`-5`・`+5`)・UUID でない末尾・人が置いた
    /// `mokume-test-<数字>-…` は `nil` で、掃かない。pid が 1 以上でなければ `nil`。
    public static func ownerPid(ofName name: String) -> pid_t? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        let parts = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty, parts[0].allSatisfy({ ("0"..."9").contains($0) }),
            let pid = pid_t(parts[0]), pid > 0,
            UUID(uuidString: String(parts[1])) != nil
        else { return nil }
        return pid
    }

    /// `directory` の下の、持ち主の居ない検査の親を消す。
    ///
    /// - Parameter isAlive: pid のプロセスが居るか。検査から差し替える。
    /// - Returns: 消した親。消せなかったものは含めない。
    @discardableResult
    public static func sweepDead(
        in directory: URL, isAlive: (pid_t) -> Bool = processExists
    ) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed: [URL] = []
        for name in names {
            guard let pid = ownerPid(ofName: name), !isAlive(pid) else { continue }
            let url = directory.appendingPathComponent(name)
            if ScratchRemoval.remove(url) { removed.append(url) }
        }
        return removed
    }
}

/// **プロセスごとの親の下に集めて、プロセスの終わりに消す、検査の一時の区画。**
///
/// 区画は一時の場所の直下の `mokume-test-<pid>-<uuid>/` の下に、今までの
/// `<prefix>-<UUID>` の名前のまま作る (`atexit` で親ごと消す・`TemplateBuildTests` の
/// `SharedDebugScratch` と同じ作法)。**`atexit` は CI のキャンセル・timeout・クラッシュでは走らない**
/// ので、最初の使用のときに ``ScratchSweep`` が、持ち主の pid が死んでいる古い親を掃く
/// (別の作業ツリー・セッションが残したものも含む)。生きている検査の親は触らない。
public nonisolated enum TestScratch {
    /// このプロセスの親。初めて引いたときに、古い親を掃き、親を作り、終わりの後始末を頼む。
    public static let root: URL = {
        let base = FileManager.default.temporaryDirectory
        ScratchSweep.sweepDead(in: base)
        let root = base.appendingPathComponent(
            "\(ScratchSweep.prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        // 親が作れないまま進むと、後の検査が「親が無い」とは読めない書き込みの失敗で落ちる。
        // 検査の補助なので、理由 (場所と OS の誤り) を言って止まる
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            fatalError("検査の一時の親を作れない: \(root.path): \(error)")
        }
        atexit {
            _ = TestScratch.owner.removeAll()
            _ = ScratchRemoval.remove(TestScratch.root)
        }
        return root
    }()

    /// 登録の本体 (親は ``root``)。
    public static let owner = ScratchOwner(base: root)

    /// `<prefix>-<UUID>` の空の区画を ``root`` の下に作る。
    public static func directory(_ prefix: String) throws -> URL {
        try owner.directory(prefix)
    }

    /// ``root`` の下の `<prefix>-<UUID>[.<pathExtension>]` を返す (作らない)。
    public static func path(
        _ prefix: String, pathExtension: String? = nil, isDirectory: Bool = false
    ) -> URL {
        owner.path(prefix, pathExtension: pathExtension, isDirectory: isDirectory)
    }

    /// 呼び手が名前を決める ``root`` の下の場所を登録して返す (作らない)。
    public static func path(named name: String, isDirectory: Bool = false) -> URL {
        owner.path(named: name, isDirectory: isDirectory)
    }

    /// 検査が別の方法で作った場所を預ける。
    public static func adopt(_ url: URL) {
        owner.adopt(url)
    }
}
