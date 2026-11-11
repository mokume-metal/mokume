// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 記録の行き先を 1 つの実行に絞る錠 ([#3570])。
///
/// ## なぜ要るのか
///
/// 同じ行き先へ 2 つの実行が書くと、互いの書き途中のファイルと完成品を壊す。行き先の隣の
/// `<行き先>.lock` に **`flock` の排他の錠** (`LOCK_EX | LOCK_NB`) を取り、取れなければ**記録を始めず理由を言う**
/// (走り続ける)。錠はファイルの記述子が握るので、**プロセスが落ちても (`SIGKILL` でも) 手放される** — 落ちた回の
/// 錠のファイルが残っていても、次の実行は取れる。
///
/// 錠を取った実行だけが、前の回の完成品と `.partial` を消せる (``discardPrevious()``)。取れなかった実行は、
/// 先に書いている実行のファイルに触らない。
///
/// 錠のファイルは手放すときに消す。消えたファイルの錠を、消える前に開いていた別の実行が取る競合は、
/// 取った後に「名前が指すファイルが握った記述子のものか」を照らして取り直す。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
nonisolated final class ReplayClaim {
    /// 記録の行き先。
    let destination: URL
    private let lockPath: String
    private var descriptor: Int32

    private init(destination: URL, lockPath: String, descriptor: Int32) {
        self.destination = destination
        self.lockPath = lockPath
        self.descriptor = descriptor
    }

    deinit { release() }

    /// 錠を取る。**行き先の親が無ければ作る。** 取れなければ `nil` と理由。
    static func take(destination: URL) -> (claim: ReplayClaim?, failure: String?) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return (nil, "\(destination.path) is a directory, not a file")
        }
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return (nil, "Could not create the folder of \(destination.path): \(error.localizedDescription)")
        }
        let lockPath = destination.path + lockSuffix
        // 取るまでの間に、持ち主が錠のファイルを消していたら取り直す (数回で足りる)
        for _ in 0..<4 {
            let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                return (nil, "Could not open \(lockPath): \(String(cString: strerror(errno)))")
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(descriptor)
                if code == EWOULDBLOCK {
                    return (
                        nil,
                        "another run is already recording to \(destination.path) "
                            + "(\(lockPath) is held by it), and two runs would break each other's file"
                    )
                }
                return (nil, "Could not lock \(lockPath): \(String(cString: strerror(code)))")
            }
            var held = stat()
            var named = stat()
            if fstat(descriptor, &held) == 0, stat(lockPath, &named) == 0, held.st_ino == named.st_ino,
                held.st_dev == named.st_dev
            {
                return (ReplayClaim(destination: destination, lockPath: lockPath, descriptor: descriptor), nil)
            }
            close(descriptor)
        }
        return (nil, "Could not lock \(lockPath): it kept being replaced")
    }

    /// 錠のファイルの名前の末尾。
    static let lockSuffix = ".lock"
    /// 書き途中のファイルの名前の末尾。
    static let partialSuffix = ".partial"

    /// 前の回が行き先に残した完成品と、落ちた回の `.partial` を消す。**錠を取った後にだけ呼ぶ。**
    ///
    /// **記録が作るのは通常ファイルだけなので、同じ名前のフォルダは中身ごと残す** ([#3943]) — 名前の形だけで
    /// 選ぶと、行き先の隣にたまたま同じ形の名前のフォルダが在れば中身ごと消える。消すのは
    /// ``AtomicFile/remove(_:)`` (`unlink(2)` 1 回) なので、見てから消すまでの間にフォルダへ替わっても消さない。
    /// シンボリックリンクは外すだけで、指す先は壊さない。
    ///
    /// 前の回の完成品を残すと、今回の回が落ちたときに今回のものと取り違えられる。**記録を始めない回
    /// (実時間の時計) も、これは先に済ませる** — 古い完成品が「今回の記録」として残らない。
    ///
    /// [#3943]: https://github.com/mokume-metal/mokume/issues/3943
    ///
    /// - Returns: 消せなかったときの理由。
    func discardPrevious() -> String? {
        // 錠を取る前に ``take(destination:)`` が見てから、ここまでの間にフォルダへ替わっていても消さない (#3943)
        if let code = AtomicFile.unlinkFile(destination) {
            if code == EISDIR || (code == EPERM && AtomicFile.isDirectory(destination, following: false)) {
                return "\(destination.path) is a directory, not a file"
            }
            return "Could not replace \(destination.path): \(String(cString: strerror(code)))"
        }
        // 錠を握っているので、同じ行き先の `.partial` はどれも死んだ実行のもの
        let directory = destination.deletingLastPathComponent().path
        let name = destination.lastPathComponent
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where Self.isPartial(entry, of: name) {
            AtomicFile.remove(URL(fileURLWithPath: directory + "/" + entry))
        }
        return nil
    }

    /// `<名前>.<プロセス番号>.partial` の形か。
    static func isPartial(_ entry: String, of name: String) -> Bool {
        let prefix = name + "."
        let suffix = partialSuffix
        guard entry.count > prefix.count + suffix.count, entry.hasPrefix(prefix), entry.hasSuffix(suffix) else {
            return false
        }
        return entry.dropFirst(prefix.count).dropLast(suffix.count).allSatisfy { ("0"..."9").contains($0) }
    }

    /// 錠を手放す。錠のファイルも消す。2 度目からは何もしない。
    func release() {
        guard descriptor >= 0 else { return }
        unlink(lockPath)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
