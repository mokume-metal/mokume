// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// ファイルの保存を拾う。
///
/// ## 見張るのはファイルと、その親ディレクトリの両方
///
/// 保存の仕方は編集器によって 2 通りある。**その場で書き換える**書き方はファイル側で
/// しか拾えず、**別名で書いてから置き換える**書き方はディレクトリ側でしか拾えない
/// (置き換えると、開いていたファイルは古い中身のまま孤立する)。片方だけの実装は
/// 単体の検査で緑のまま実機で動かないので、最初から両方に張る。
///
/// ## 置き換えられたら見張り直す
///
/// 置き換え保存のあと、ファイル側の見張りは**消えたファイル**を指したままになる。
/// 2 回目の保存が届かないのはこれが原因で、**1 回保存して届くかの検査には判別力が
/// 無い** — 誤った実装でも 1 回目は通り、死ぬのは 2 回目以降である。だから拾うたびに
/// ファイル側を張り直す。
///
/// ## 主キューへ直に載せない
///
/// 見張りは**自前の待ち行列**で受け、そこから main actor へ渡す。主キューへ直に
/// 載せると、主キューが捌かれる仕組みのある実行 (窓のあるアプリ) でしか届かない —
/// 検査の実行では捌かれず、**実装が正しくても届かない**ことを実測した。
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private let queue = DispatchQueue(label: "org.mokume.shader-watch")
    /// いま見張っているファイルの通し番号。置き換えられると変わる。
    private var watchedIdentifier: UInt64?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        watchDirectory()
        watchFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    /// いま見張れているか (検査から確かめるため)。
    var isWatchingFile: Bool { fileSource != nil }
    var isWatchingDirectory: Bool { directorySource != nil }

    /// 見張っている相手が、いまその場所にあるファイルと同じか。
    ///
    /// 置き換え保存の直後、張り直しが済むまでの短い間だけ食い違う。**待つ側が
    /// 時間ではなくこれを見られる**ようにしてある。
    var watchesCurrentFile: Bool {
        watchedIdentifier != nil && watchedIdentifier == Self.identifier(of: url.path)
    }

    /// その場所にあるファイルの通し番号。
    private nonisolated static func identifier(of path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        fileSource = Self.makeSource(
            path: url.path, mask: [.write, .delete, .rename, .extend], queue: queue,
            onEvent: { [weak self] in Task { @MainActor in self?.handle() } })
        watchedIdentifier = Self.identifier(of: url.path)
    }

    private func watchDirectory() {
        directorySource = Self.makeSource(
            path: url.deletingLastPathComponent().path, mask: [.write], queue: queue,
            onEvent: { [weak self] in Task { @MainActor in self?.handle() } })
    }

    /// 見張りを 1 本張る。
    ///
    /// **隔離の外で組み立てる。** 待ち行列から呼ばれる手続きは main actor では走らない
    /// ので、main actor を既定とする文脈で組み立てると、後片付けの手続きが隔離の検査に
    /// 引っかかって落ちる (実測)。
    private nonisolated static func makeSource(
        path: String, mask: DispatchSource.FileSystemEvent, queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// 変化を拾った。
    private func handle() {
        // **張り直してから知らせる。** 置き換え保存では、いま見ているファイルは
        // もう別のものになっている
        watchFile()
        onChange()
    }
}
