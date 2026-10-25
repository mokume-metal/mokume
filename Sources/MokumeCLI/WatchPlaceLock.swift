// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import mokume

/// 場所 (`.mokume/`) を見張っているのは 1 本だけ、を表す錠 ([#2093](https://github.com/mokume-metal/mokume/issues/2093))。
///
/// ## なぜ要るのか
///
/// 見張りは、場所の区画を**自分 1 本のものとして**扱う。作り直し (`openViewer`) は区画 `viewport` を
/// 「前の見張りが残した、死んだ面を指すもの」とみなして消し、後始末も区画を消す。同じ場所に 2 本目が
/// 居ると、2 本目が 1 本目の区画を作り直してその子が目録を書き、1 本目の窓が 2 本目の子を映し、2 本目を
/// 止めると 1 本目の次の世代が自分の窓を開いて、前の世代が並んで生き続けた (#2095 の実測)。
/// 合図 (`MOKUME_VIEWPORT_OWNER`) は「見張りに起こされたか」は伝えるが、**どの見張りか**は区別しない。
///
/// ## 何をするのか
///
/// 区画に応える権利 (`FacetClaim`) と同じ形で、場所の中の錠ファイルへ `flock` を掛ける。
/// **先に居る見張りが消えるまで持ち、後から来た見張りは断って終わる。**
///
/// - 錠は**開いた記述ごと**で、プロセスの終わりにカーネルが外す。`SIGKILL` で消えた前任の場所では
///   取れる — 取れたなら先客は居ないので、残った区画は作り直してよい (`openViewer` の前提が、仮定
///   から確かめた事実になる)。道具からの合図も pid も要らない
/// - **`O_CLOEXEC` で開く。** 子へ記述が継がれると、見張りが消えたあとも子が錠を握り続け、起こし直した
///   見張りを断り続ける
/// - 場所は `.mokume/` である (`MOKUME_WORK_DIR` が動かす基準の下)。別のスケッチ・同じスケッチでも基準を
///   分けた 2 本は、別の場所なので互いに断らない
///
/// ## 確かめられなければ、取れたことにする
///
/// 場所を作れない・錠のファイルを開けない・`flock` が使えないファイルシステムでは、断らずに見張り
/// 始める。**この型が無かった頃の振る舞いに倒す** (`FacetClaim` と同じ向き) — 断るほうに倒すと、錠を
/// 置けない場所では見張りが 1 本も始まらない。
nonisolated final class WatchPlaceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// 場所の錠ファイル。**点で始める** — 読み手が場所を覗いたときに、区画と並んで目に入らない
    /// ようにする (`WorkDirectory.claimURL(under:)` と同じ理由)。中身は空のまま置かれる。
    static func lockURL(under base: URL) -> URL {
        WorkDirectory.root(under: base).appendingPathComponent(".watch-lock")
    }

    /// その場所を見張る権利を取る。
    ///
    /// - Parameter base: 区画の基準 (`MOKUME_WORK_DIR` か、スケッチの場所)。
    /// - Parameter afterLocking: 錠を掛けた直後に呼ぶ口。**検査が、錠を掛けた後に場所を消される競合を
    ///   作るためにある。**
    /// - Throws: 同じ場所を別の見張りが持っているとき ``CommandFailure/alreadyWatching(place:pid:)``。
    ///   **場所の中には何も作り直さない** — 断った回は区画にも触れない。
    static func claim(
        under base: URL, afterLocking: () -> Void = {}
    ) throws(CommandFailure) -> WatchPlaceLock {
        let place = WorkDirectory.root(under: base)
        let lock = lockURL(under: base)
        // **開いたファイルと、パスが指すファイルが同じことを確かめる。** 錠を掛けた直後に `.mokume` ごと
        // 消されると、掛けたのは消えたファイルの錠で、あとから同じパスに作られたファイルを持つ別の見張りと
        // 並んでしまう。違えば取り直す (走っている間に `.mokume` ごと消される場合は、区画も壊れるので
        // この型の範囲外である)
        for _ in 0..<5 {
            // 場所を作れなければ確かめられない (読めないところでは区画も置けず、別の失敗が名乗る)
            guard
                (try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true))
                    != nil
            else { return WatchPlaceLock(descriptor: -1) }
            let opened = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard opened >= 0 else { return WatchPlaceLock(descriptor: -1) }
            var locked = flock(opened, LOCK_EX | LOCK_NB) == 0
            var reason = locked ? 0 : errno
            // **先客が居ないと読めるのに断られたなら、窓口の共有の探り (``isHeld(under:)``) と重なっただけかもしれない。**
            // 探りはすぐ離すので、短く取り直す。先客が生きていれば (pid が居る) 待たずに断る
            var waited = 0
            while !locked, reason == EWOULDBLOCK, waited < contendedRetries, !holderIsAlive(lock) {
                waited += 1
                usleep(contendedPause)
                locked = flock(opened, LOCK_EX | LOCK_NB) == 0
                reason = locked ? 0 : errno
            }
            guard locked else {
                close(opened)
                // **先客が居るときだけ断る。** それ以外の失敗は確かめられないので、取れたことにする
                guard reason == EWOULDBLOCK else { return WatchPlaceLock(descriptor: -1) }
                throw .alreadyWatching(place: place.path, pid: holder(of: lock))
            }
            afterLocking()
            if sameFile(descriptor: opened, path: lock.path) {
                // 診断のために自分の pid を書く。**判定は錠だけである** — 読めなくても断る
                let text = "\(getpid())\n"
                _ = ftruncate(opened, 0)
                _ = text.withCString { pwrite(opened, $0, strlen($0), 0) }
                return WatchPlaceLock(descriptor: opened)
            }
            close(opened)
        }
        // 取り直しても落ち着かない場所は、確かめられない
        return WatchPlaceLock(descriptor: -1)
    }

    /// 先客と読めるものを待たずに断るのをやめて、取り直す回数と間隔 (マイクロ秒)。合わせて 100 ms ほど。
    private static let contendedRetries = 10
    private static let contendedPause: useconds_t = 10_000

    /// 錠ファイルに書かれた pid のプロセスが居るか。**書かれていない・読めないときは居ないと読む。**
    private static func holderIsAlive(_ lock: URL) -> Bool {
        guard let pid = holder(of: lock), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// 開いている記述と、パスが指すファイルが同じか。パスが無ければ違う。
    private static func sameFile(descriptor: Int32, path: String) -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0, stat(path, &named) == 0 else { return false }
        return opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    /// 錠ファイルに書かれた先客の pid。**診断のためだけで、無くても断る。**
    private static func holder(of lock: URL) -> Int32? {
        guard let text = try? String(contentsOf: lock, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// その場所を、いま見張りが持っているか ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
    ///
    /// **窓口 (MCP) が、見張りの残した記録 (`build/status.json`) を「いまの話」として読んでよいかを見る。**
    /// 記録は見張りが終わっても残るので、見張りを止めた後に手で起こし直した作品の件に、止まる前の
    /// 「起動できなかった」を答えてしまう。錠はプロセスの終わりにカーネルが外すので、`SIGKILL` で消えた
    /// 見張りは持っていないと読める (pid の生死を当てにしない)。
    ///
    /// - **排他の錠は取らない。** 先に錠ファイルに書かれた pid が居なければ、錠に触れずに「持たれていない」と
    ///   答える。居る (または読めない) ときだけ、**共有の錠を試して (すぐ離し)**、断られれば持たれていると読む。
    ///   その一瞬に別の見張りが `claim(under:)` を打つと、`claim` は先客が居ないと読める間 (pid が無い・居ない)
    ///   は短く取り直すので、実在しない先客で断らない。
    /// - **確かめられなければ、持たれていないと読む** (錠ファイルが無い・開けない・`flock` が使えない場所)。
    ///   窓口はそのとき、記録を使わず元の案内に倒れる。
    static func isHeld(under base: URL) -> Bool {
        let lock = lockURL(under: base)
        if let pid = holder(of: lock), pid > 0, kill(pid, 0) != 0, errno == ESRCH { return false }
        let probe = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        if flock(probe, LOCK_SH | LOCK_NB) == 0 {
            flock(probe, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// 手放す。**見張りが終わるとき、後始末の後に呼ぶ。** 呼ばなくても、プロセスの終わりが外す。
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
