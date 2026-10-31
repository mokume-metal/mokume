// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeCore
import Synchronization

/// 見えている MIDI の入力 1 つ。
nonisolated struct MIDISourceInfo: Sendable, Equatable {
    /// CoreMIDI が機材 (の端点) に振る一意な番号 (`kMIDIPropertyUniqueID`)。挿し直しても同じになりやすい。
    var uniqueID: Int32
    /// 人が読む名前 (`kMIDIPropertyDisplayName`)。
    var name: String
    /// CoreMIDI の端点 (`MIDIEndpointRef`)。挿し直すと変わる。偽の機材では 0。
    var endpoint: UInt32
}

/// CoreMIDI への継ぎ目。**係 (``MIDIHub``) が CoreMIDI に触れるのはここだけ**で、検査は偽の実装で
/// 抜き差しと届く語を直に渡す (実機の MIDI 機材は要らない・[ADR-0028] 決定 6)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
protocol MIDIBackend: AnyObject {
    /// 見張り始める。機材の追加・削除・変更があったら `changed` を呼ぶ (どのスレッドからでもよい)。
    func start(changed: @escaping @Sendable () -> Void)
    /// いま使える入力の一覧。外されている (オフラインの) 機材は含めない。
    func sources() -> [MIDISourceInfo]
    /// 受け始める。届いた UMP の語と host time を `handler` へ渡す (**任意のスレッドから**呼ばれる)。
    /// 繋げたか (`false` なら受け取り先を持たない。係が次の ``MIDIHub/refresh()`` で繋ぎ直す)。
    func connect(
        _ source: MIDISourceInfo, handler: @escaping @Sendable (_ words: [UInt32], _ hostTime: UInt64) -> Void
    ) -> Bool
    /// 受けるのをやめる。
    func disconnect(_ source: MIDISourceInfo)
}

/// 実機の MIDI 入力を見張る係。
///
/// プロセスに 1 つ (``shared``) で、**最初に ``Sketch/midiDevices()`` か ``Sketch/createMIDI(_:)`` が呼ばれた
/// ときに始まる**。`import mokume` しただけでは CoreMIDI に触れない ([ADR-0042] 決定 1)。
///
/// ## 待ち行列は作らない
///
/// 機材の追加・削除の知らせは main へ寄せて受ける。届いたメッセージは CoreMIDI が呼ぶスレッドで
/// ``MIDIFeed`` (`Sendable`) へ入れるところで手を離す (受け渡しの 3 層の 1 層目・[ADR-0042] 決定 4)。
/// 新しい待ち行列は持たない ([ADR-0010] 決定 4)。
///
/// ## 席と中継
///
/// 識別子 1 つ (``MIDISlots`` が振る) に中継 (``MIDIFeed``) が 1 つあり、抜き差しを跨いで残る。挿し直した
/// 機材は同じ中継へ入れるので、その識別子の ``MIDIPort`` はそのまま戻る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class MIDIHub {
    /// 走っているプロセスの係。
    static let shared = MIDIHub(backend: CoreMIDIBackend())

    /// 振った識別子と、いま繋がっているもの。
    private(set) var slots = MIDISlots()
    private var bound: [Int32: (source: MIDISourceInfo, id: String)] = [:]
    /// 見えているが繋げなかった機材 (一意な番号 → 識別子)。次の ``refresh()`` で繋ぎ直す。
    private var failed: [Int32: String] = [:]
    private var feeds: [String: MIDIFeed] = [:]
    private var started = false
    private let backend: any MIDIBackend

    init(backend: any MIDIBackend) {
        self.backend = backend
    }

    /// 見張り始め、いま繋がっている機材を並べる。2 度目からは何もしない。
    func start() {
        guard !started else { return }
        started = true
        backend.start { [weak self] in
            // 知らせは CoreMIDI のスレッドで届きうる。main へ寄せて、一覧を引き直す
            // (新しい待ち行列は持たない・ADR-0010 決定 4)
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// 繋がっている一覧を引き直し、差を抜き差しとして入れる (検査は偽の機材を変えてから直に呼ぶ)。
    func refresh() {
        let current = backend.sources()
        var seen: Set<Int32> = []
        let present = current.filter { seen.insert($0.uniqueID).inserted }

        // 抜かれた。**端点が変わったものも、いったん抜かれたことにする** (挿し直しが 1 回の知らせに収まった)。
        // 端点が同じで名前だけ変わったものは抜かない (下で名前だけ直す)
        let gone = bound.filter { uid, entry in
            !present.contains(where: { $0.uniqueID == uid && $0.endpoint == entry.source.endpoint })
        }
        for (uid, entry) in gone.sorted(by: { $0.key < $1.key }) {
            bound[uid] = nil
            slots.disconnect(entry.id)
            backend.disconnect(entry.source)
            for inbox in feed(for: entry.id).inboxes { inbox.unplug() }
        }
        // 繋げないまま抜かれた機材
        for (uid, id) in failed.sorted(by: { $0.key < $1.key }) where !present.contains(where: { $0.uniqueID == uid }) {
            failed[uid] = nil
            for inbox in feed(for: id).inboxes { inbox.unplug() }
        }
        // 名前だけが変わった
        for source in present {
            guard var entry = bound[source.uniqueID], entry.source.name != source.name else { continue }
            entry.source.name = source.name
            bound[source.uniqueID] = entry
            slots.rename(entry.id, to: source.name)
        }
        // 繋がった。**一意な番号の順に**識別子を振る — OS が一覧する順は起動ごとに変わりうるので、同じ名前の
        // 機材の番号が、起動をまたいで入れ替わらないようにする
        for source in present.sorted(by: { $0.uniqueID < $1.uniqueID }) where bound[source.uniqueID] == nil {
            let id = slots.connect(uniqueID: source.uniqueID, name: source.name)
            let feed = feed(for: id)
            // 受け始めてから名乗ると、その間に届いたものを「抜かれている」と捨てる。先に名乗る
            feed.setState(.running)
            if backend.connect(source, handler: { [feed] words, hostTime in feed.receive(words, hostTime: hostTime) }) {
                bound[source.uniqueID] = (source, id)
                failed[source.uniqueID] = nil
            } else {
                // 繋げなかった。繋がっていると名乗らず、一覧には載せる (次の `refresh()` で繋ぎ直す)
                slots.disconnect(id)
                failed[source.uniqueID] = id
                feed.setState(.unavailable)
            }
        }
    }

    /// 一覧に載せる機材。初めて繋がった順で、抜かれたものも残る。
    var devices: [MIDIDevice] {
        slots.known.map { id in
            MIDIDevice(id: id, name: slots.name(of: id) ?? id, isConnected: slots.isConnected(id))
        }
    }

    // MARK: - 入り口から

    /// `id` の中継へ入れ物を繋ぐ。
    func subscribe(_ inbox: MIDIInbox, to id: String) {
        // 状態を先に決める。足した後に決めると、足した直後に届いたものを「抜かれている」と捨てる
        if slots.isConnected(id) {
            inbox.setState(.running)
        } else if failed.values.contains(id) {
            inbox.setState(.unavailable)
        } else {
            inbox.setState(slots.known.contains(id) ? .disconnected : .unavailable)
        }
        feed(for: id).add(inbox)
    }

    /// `id` の中継から入れ物を外す。
    func unsubscribe(_ inbox: MIDIInbox, from id: String) {
        feeds[id]?.remove(inbox)
    }

    private func feed(for id: String) -> MIDIFeed {
        if let feed = feeds[id] { return feed }
        let feed = MIDIFeed()
        feeds[id] = feed
        return feed
    }
}

/// 識別子 1 つぶんの中継。届いた語を読み、繋がっている入れ物すべてへ入れる。
///
/// **どのスレッドから呼ばれてもよい** (CoreMIDI の受け取りの口は隔離の外で呼ばれる)。入れ物は弱く持つ —
/// 入れ物を持つのは入り口 (``MIDIPort``) で、閉じずに捨てられた入り口のぶんがここに溜まらない。
///
/// **コントロールチェンジの最後の表と、数えた拍を持つ。** 入れ物が無い間に動いたつまみも、届いたクロックも数え、
/// 後から繋いだ入り口・足し直された入り口へ、繋ぐ瞬間に渡す (ゲームパッドが繋いだときにいまの値を入れるのと同じ。
/// `watch` で作り直した直後に、拍が 0 へ戻らない)。表と拍の更新と入れ物への配りは、繋ぐ処理と同じ錠の内側で行う —
/// 外すと、繋ぐ瞬間に古いものが新しい値を上書きする。
nonisolated final class MIDIFeed: Sendable {
    private struct State: Sendable {
        var entries: [Entry] = []
        var controllers = MIDIControllers()
        var clock = MIDIClock()
    }
    private let state = Mutex(State())

    private struct Entry: Sendable {
        weak var inbox: MIDIInbox?
    }

    /// 繋がっている入れ物。
    var inboxes: [MIDIInbox] {
        state.withLock { $0.entries.compactMap(\.inbox) }
    }

    /// 入れ物を繋ぎ、ここまでに届いたコントロールチェンジの現在値と数えた拍を渡す。
    func add(_ inbox: MIDIInbox) {
        state.withLock { state in
            state.entries.removeAll { $0.inbox == nil || $0.inbox === inbox }
            state.entries.append(Entry(inbox: inbox))
            inbox.adopt(state.controllers, clock: state.clock)
        }
    }

    func remove(_ inbox: MIDIInbox) {
        state.withLock { state in state.entries.removeAll { $0.inbox == nil || $0.inbox === inbox } }
    }

    func setState(_ state: SourceState) {
        for inbox in inboxes { inbox.setState(state) }
    }

    /// 届いた語を読んで、表と拍を更新し、入れ物へ入れる。入れ物が無くても表と拍は更新する。
    func receive(_ words: [UInt32], hostTime: UInt64) {
        let decoded = MIDIUMP.decode(words)
        guard !decoded.messages.isEmpty || decoded.unreadable > 0 else { return }
        state.withLock { state in
            for message in decoded.messages {
                if case .controlChange(let channel, let controller, let value) = message, message.isValid {
                    state.controllers.set(channel: channel, controller: controller, value: value)
                }
                state.clock.apply(message)
            }
            for inbox in state.entries.compactMap(\.inbox) {
                for message in decoded.messages { inbox.receive(message, hostTime: hostTime) }
                if decoded.unreadable > 0 { inbox.discardUnreadable(decoded.unreadable) }
            }
        }
    }
}
