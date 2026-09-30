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
/// その場所のファイルの通し番号を見て、**相手が入れ替わっていれば**ファイル側を張り直す。
///
/// 入れ替わっていなければ張り直さない。親ディレクトリの書き込みも拾うので、断片と同じ
/// ディレクトリへ連番を書き出すと事象はフレームごとに起きる。そのたびに張り直すと、毎フレーム
/// ファイルを開き直すことになる ([#1830] の反証 2)。中身が変わっていなければ、扱う費用は
/// 通し番号を読む 1 回と、持ち主が中身を読んで比べる 1 回で止まる (``ShaderBox/reload(_:)``)。
///
/// ## 主キューへ直に載せない
///
/// 見張りは**自前の待ち行列**で受け、そこから main actor へ渡す。主キューへ直に
/// 載せると、主キューが捌かれる仕組みのある実行 (窓のあるアプリ) でしか届かない —
/// 検査の実行では捌かれず、**実装が正しくても届かない**ことを実測した。
///
/// ## main actor へ積むのは 1 本まで
///
/// 事象ごとに 1 本積むと、main actor を譲らずにフレームを回す経路では 1 本も走れず、
/// フレームに比例して溜まる ([#1594] と同じ形)。親ディレクトリの書き込みも拾うので、保存や
/// 連番の書き出しの行き先が見張る断片と同じディレクトリなら、事象はフレームごとに起きる。
/// 知らせは ``CoalescedNotices`` で合体する — 拾ったときにすることは「張り直して知らせる」
/// だけで、何回変わったかは要らない。
///
/// ## 扱うのは、印を取った側
///
/// 拾ったらその場で**印を立てる**。扱う (張り直して知らせる) のは、印を取った側である。取る側は
/// 2 つある:
///
/// - **本体の面のフレームの頭** (``takeChanges()``)。本体の面とは時刻の置き場の持ち主で、
///   ランタイムの面も、利用者が `Canvas(target:gpu:)` で作って直に回す面もこれに当たる
/// - 積んだ `Task` が走ったとき (main actor を譲ったとき)。フレームを描かずに譲る経路 (止めた
///   スケッチの窓など) でも届く
///
/// かつては `Task` しか取らなかったので、main actor を譲らずにフレームを回すループ (窓を出さない
/// 書き出しや検査。``SketchRuntime/advance()`` でも、面を直に回すのでも) では 1 本も走らず、何
/// フレーム回しても古い断片のまま描いた ([#1830])。誰が `advance()` を叩くかは外側の話
/// (``SketchRuntime`` の説明) なので、叩き方で届き方が変わってはならない (#1704 が `@Param` の知らせで
/// 同じ形を直した)。
///
/// **取るのは本体の面のフレームの頭で、描き場所の描き始めではない。** 描き場所
/// (`createGraphics`) は本体のフレームの中で描かれるので、そこで取ると外のフレームの途中で
/// 組み直し、1 つのフレームの中で古い断片と新しい断片が混ざる。`Task` の側も、描いている最中は
/// 走らない (描く手続きは譲らない)。**別々に作った本体の面どうしを入れ子に描く**使い方 (面 A の
/// `draw` の中で面 B の `draw` を回す) では、内側の頭が外側のフレームの途中に来る。これは約束の外
/// で、ランタイムはこの形を作らない。
///
/// **取るのは、そのプロセスで生きている見張りの全部である。** 一覧は型に 1 つで、どの本体の面の
/// フレームの頭も、自分の面で読み込んだ断片に限らず全員の印を取る。取る時点はどの面にとっても
/// フレームの外 (上の入れ子を除く) なので、混ざることはない。数えを見る検査は、自分が作った
/// 見張りの印が他の検査のフレームで取られうることを前提に書く。
///
/// 印は 1 つなので、両方の側が同じ変化を 2 度扱うことはない。
///
/// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
/// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private let queue = DispatchQueue(label: "org.mokume.shader-watch")
    /// いま見張っているファイルの通し番号。置き換えられると変わる。
    private var watchedIdentifier: UInt64?
    /// 拾った事象を main actor へ渡す前に合体する器。
    private let notices = CoalescedNotices()
    /// 拾った変化の印。扱う側が取る (冒頭の「扱うのは、印を取った側」)。印の形は `@Param` の
    /// 知らせと同じもので足りる (拾った糸で立て、main actor で取る)。
    private let change = DeclarationNotice()

    /// 生きている見張り。本体の面がフレームの頭で回す (``takeChanges()``)。**弱く持つ** —
    /// 見張りの寿命は断片の持ち主が決める。死んだものは回すときに落とす。
    private static var live: [Weak] = []
    private struct Weak { weak var watcher: FileWatcher? }

    /// 診断: 拾った事象の数。
    var arrivedEventCount: Int { notices.arrived }
    /// 診断: main actor へ積んだまま、まだ走っていない知らせの数。**1 を超えない。**
    var queuedNoticeCount: Int { notices.queued }
    /// 診断: 拾った変化を扱った回数 (張り直して知らせた数)。
    ///
    /// **他の面のフレームで扱われた分も入る** (冒頭の「取るのは、そのプロセスで生きている見張りの
    /// 全部である」)。並列の検査では、別の検査のフレームの頭がこの見張りの印を取りうる。
    private(set) var handledCount = 0
    /// 診断: ファイル側に見張りを張った回数 (初めの 1 回を含む)。
    private(set) var fileWatchCount = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        watchDirectory()
        watchFile()
        Self.live.removeAll { $0.watcher == nil }
        Self.live.append(Weak(watcher: self))
    }

    /// 生きている見張りのうち、印の立ったものを扱う。**本体の面のフレームの頭で呼ぶ**
    /// (``Canvas`` の `beginFrame()` が呼ぶ・冒頭の「扱うのは、印を取った側」)。
    static func takeChanges() {
        live.removeAll { $0.watcher == nil }
        // 回すのは呼んだ時点の写し。扱う中 (持ち主の reload) で一覧が変わっても崩れない
        for entry in live { entry.watcher?.takeChange() }
    }

    /// 印が立っていれば下ろして扱う。
    private func takeChange() {
        guard change.take() else { return }
        handle()
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
        fileWatchCount += 1
        fileSource?.cancel()
        fileSource = nil
        fileSource = Self.makeSource(
            path: url.path, mask: [.write, .delete, .rename, .extend], queue: queue,
            onEvent: onEvent)
        watchedIdentifier = Self.identifier(of: url.path)
    }

    private func watchDirectory() {
        directorySource = Self.makeSource(
            path: url.deletingLastPathComponent().path, mask: [.write], queue: queue,
            onEvent: onEvent)
    }

    /// 見張りが事象を拾ったときの手続き。**印を立て、積んだまま走っていない知らせがあれば
    /// 積まない。**
    ///
    /// 積んだ印は自分の生死によらず下ろす (``RenderDevice`` の完了の知らせと同じ)。**印は積む前に
    /// 立てる** — 走った `Task` が印を取った後に届いた事象は、立て直した印をもう 1 本の `Task` か
    /// 次のフレームの頭が取る。
    private var onEvent: @Sendable () -> Void {
        { [weak self, notices, change] in
            change.raise()
            guard notices.arrive(0) else { return }
            Task { @MainActor in
                _ = notices.take()
                self?.takeChange()
            }
        }
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
        handledCount += 1
        // **張り直してから知らせる。** 置き換え保存では、いま見ているファイルは
        // もう別のものになっている。入れ替わっていなければ張り直さない (冒頭)
        if !watchesCurrentFile || fileSource == nil { watchFile() }
        onChange()
    }
}
