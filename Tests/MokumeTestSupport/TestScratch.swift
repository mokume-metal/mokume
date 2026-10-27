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
    /// - Returns: 消せなかった場所 (読めない親など)。1 つが消せなくても残りは消し続ける。
    @discardableResult
    public func removeAll() -> [URL] {
        let urls = lock.withLock {
            let urls = owned
            owned = []
            return urls
        }
        var failed: [URL] = []
        for url in urls {
            // 検査が既に消した (自分で `defer` した) 場所は在らないので、失敗ではない
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failed.append(url)
            }
        }
        return failed
    }
}

/// **プロセスの終わりに消す、検査の一時の区画。**
///
/// 全検査が 1 つを分け持ち、`atexit` で消す (`TemplateBuildTests` の `SharedDebugScratch` と同じ作法)。
/// 区画の名前と置き場所は、今までの `temporaryDirectory.appendingPathComponent("mokume-…-<UUID>")` と
/// 同じなので、検査の中身は変わらない。
public nonisolated enum TestScratch {
    /// 登録の本体。初めて引いたときに、プロセスの終わりの後始末を頼む。
    public static let owner: ScratchOwner = {
        let owner = ScratchOwner()
        atexit { _ = TestScratch.owner.removeAll() }
        return owner
    }()

    /// `<prefix>-<UUID>` の空の区画を一時の場所の直下に作る。
    public static func directory(_ prefix: String) throws -> URL {
        try owner.directory(prefix)
    }

    /// 一時の場所の直下の `<prefix>-<UUID>[.<pathExtension>]` を返す (作らない)。
    public static func path(
        _ prefix: String, pathExtension: String? = nil, isDirectory: Bool = false
    ) -> URL {
        owner.path(prefix, pathExtension: pathExtension, isDirectory: isDirectory)
    }

    /// 呼び手が名前を決める一時の場所の直下の場所を登録して返す (作らない)。
    public static func path(named name: String, isDirectory: Bool = false) -> URL {
        owner.path(named: name, isDirectory: isDirectory)
    }

    /// 検査が別の方法で作った場所を預ける。
    public static func adopt(_ url: URL) {
        owner.adopt(url)
    }
}
