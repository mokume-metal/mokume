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
    func connect(_ source: MIDISourceInfo, handler: @escaping @Sendable (_ words: [UInt32], _ hostTime: UInt64) -> Void)
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
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// 繋がっている一覧を引き直し、差を抜き差しとして入れる (検査は偽の機材を変えてから直に呼ぶ)。
    func refresh() {
        let current = backend.sources()
        var seen: Set<Int32> = []
        let present = current.filter { seen.insert($0.uniqueID).inserted }

        // 抜かれた (端点が変わったものも、いったん抜かれたことにする)
        let gone = bound.filter { uid, entry in !present.contains(where: { $0.uniqueID == uid && $0 == entry.source }) }
        for (uid, entry) in gone.sorted(by: { $0.value.id < $1.value.id }) {
            bound[uid] = nil
            slots.disconnect(entry.id)
            backend.disconnect(entry.source)
            for inbox in feed(for: entry.id).inboxes { inbox.unplug() }
        }
        // 繋がった
        for source in present where bound[source.uniqueID] == nil {
            let id = slots.connect(uniqueID: source.uniqueID, name: source.name)
            bound[source.uniqueID] = (source, id)
            let feed = feed(for: id)
            backend.connect(source) { [feed] words, hostTime in feed.receive(words, hostTime: hostTime) }
            feed.setState(.running)
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
        feed(for: id).add(inbox)
        if slots.isConnected(id) {
            inbox.setState(.running)
        } else {
            inbox.setState(slots.known.contains(id) ? .disconnected : .unavailable)
        }
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
nonisolated final class MIDIFeed: Sendable {
    private let entries = Mutex<[Entry]>([])

    private struct Entry: Sendable {
        weak var inbox: MIDIInbox?
    }

    /// 繋がっている入れ物。
    var inboxes: [MIDIInbox] {
        entries.withLock { $0.compactMap(\.inbox) }
    }

    func add(_ inbox: MIDIInbox) {
        entries.withLock { list in
            list.removeAll { $0.inbox == nil || $0.inbox === inbox }
            list.append(Entry(inbox: inbox))
        }
    }

    func remove(_ inbox: MIDIInbox) {
        entries.withLock { list in list.removeAll { $0.inbox == nil || $0.inbox === inbox } }
    }

    func setState(_ state: SourceState) {
        for inbox in inboxes { inbox.setState(state) }
    }

    /// 届いた語を読んで、入れ物へ入れる。入れ物が無ければ読まない。
    func receive(_ words: [UInt32], hostTime: UInt64) {
        let inboxes = inboxes
        guard !inboxes.isEmpty else { return }
        let decoded = MIDIUMP.decode(words)
        for inbox in inboxes {
            for message in decoded.messages { inbox.receive(message, hostTime: hostTime) }
            if decoded.unreadable > 0 { inbox.discardUnreadable(decoded.unreadable) }
        }
    }
}
