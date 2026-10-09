// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import GameController
import MokumeCore
import Synchronization

/// 実機のゲームパッドを見張る係。GameController に触れるのはこの型だけである。
///
/// プロセスに 1 つ (``shared``) で、**最初に ``Sketch/gamepads()`` が呼ばれたときに始まる**。
/// `import mokume` しただけでは何もしない ([ADR-0042] 決定 1)。
///
/// ## 待ち行列は作らない
///
/// 接続の知らせ (`GCControllerDidConnect` / `DidDisconnect`) は main で受ける。釦とスティックの
/// handler は、GameController の既定どおり main の待ち行列で呼ばれる (`handlerQueue` を変えない)。
/// 新しい待ち行列は持たない ([ADR-0010] 決定 4)。
///
/// handler は ``GamepadFeed`` (`Sendable`) へ入れるところで手を離す (受け渡しの 3 層の 1 層目・
/// [ADR-0042] 決定 4)。handler は `@Sendable` にして main actor へ隔離しない — GameController が
/// どの待ち行列から呼んでも、動的な隔離の検査で落ちない ([ADR-0042] 決定 7)。
///
/// ## 席と中継
///
/// 識別子 1 つ (``GamepadSlots`` が振る) に中継 (``GamepadFeed``) が 1 つあり、抜き差しを
/// 跨いで残る。挿し直したパッドの handler は同じ中継へ入れるので、その識別子の
/// ``Gamepad`` はそのまま戻る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
final class GamepadHub {
    /// 走っているプロセスの係。
    static let shared = GamepadHub()

    /// 振った識別子と、いま繋がっているもの。
    private(set) var slots = GamepadSlots()
    /// 繋がっている機材と、振った識別子。
    private var bound: [ObjectIdentifier: (controller: GCController, id: String)] = [:]
    private var feeds: [String: GamepadFeed] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var started = false
    private let watches: Bool

    /// - Parameter watches: 接続の知らせを受け、いま繋がっている機材を並べるか。検査は偽にして、
    ///   仮の機材を抜き差しの口へ直に渡す (手元に挿してあるパッドを拾わない)。
    init(watches: Bool = true) {
        self.watches = watches
    }

    /// 接続の知らせを受け始め、いま繋がっている機材を並べる。2 度目からは何もしない。
    func start() {
        guard !started else { return }
        started = true
        guard watches else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                [weak self] note in
                // 知らせは main で届き (queue: .main)、機材はこの場で、同じ main の上で使い切る
                nonisolated(unsafe) let controller = note.object as? GCController
                MainActor.assumeIsolated {
                    if let controller { self?.connected(controller) }
                }
            })
        observers.append(
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                [weak self] note in
                // 知らせは main で届き (queue: .main)、機材はこの場で、同じ main の上で使い切る
                nonisolated(unsafe) let controller = note.object as? GCController
                MainActor.assumeIsolated {
                    if let controller { self?.disconnected(controller) }
                }
            })
        for controller in GCController.controllers() { connected(controller) }
    }

    // MARK: - 抜き差し (検査は仮の機材でここを直に呼ぶ)

    /// 繋がった。識別子を振り、handler を中継へ繋ぎ、いまの値を入れる。
    func connected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        // 走り出しの一覧と知らせの両方で同じ機材が来ることがある
        guard bound[key] == nil else { return }
        let id = slots.connect(model: Self.model(of: controller))
        bound[key] = (controller, id)
        let feed = feed(for: id)
        Self.wire(controller, to: feed)
        feed.setState(.running)
        Self.sendCurrent(of: controller, to: feed.inboxes)
    }

    /// 抜かれた。押していた釦を離したことにして、抜かれたと名乗る。
    func disconnected(_ controller: GCController) {
        guard let (_, id) = bound.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        slots.disconnect(id)
        Self.unwire(controller)
        for inbox in feed(for: id).inboxes { inbox.unplug() }
    }

    // MARK: - 入り口から

    /// `id` の中継へ入れ物を繋ぐ。繋がっていれば、いまの値を入れる。
    func subscribe(_ inbox: GamepadInbox, to id: String) {
        feed(for: id).add(inbox)
        if let controller = bound.values.first(where: { $0.id == id })?.controller {
            inbox.setState(.running)
            Self.sendCurrent(of: controller, to: [inbox])
        } else {
            inbox.setState(slots.known.contains(id) ? .disconnected : .unavailable)
        }
    }

    /// `id` の中継から入れ物を外す。
    func unsubscribe(_ inbox: GamepadInbox, from id: String) {
        feeds[id]?.remove(inbox)
    }

    private func feed(for id: String) -> GamepadFeed {
        if let feed = feeds[id] { return feed }
        let feed = GamepadFeed()
        feeds[id] = feed
        return feed
    }

    // MARK: - GameController の要素

    /// 識別子に使う機種名。名乗らない機材は分類 (`"DualSense"` など) で呼ぶ。
    private static func model(of controller: GCController) -> String {
        if let name = controller.vendorName, !name.isEmpty { return name }
        return controller.productCategory
    }

    /// 釦ごとに、押し離しを中継へ入れる handler を付ける。左スティックには傾きを入れる handler を付ける。
    ///
    /// **1 つの釦が複数の名前を持つ** (`buttons` は名前から要素への表で、別名も並ぶ)。handler は
    /// 要素に 1 つしか付かないので、要素ごとにまとめ、その要素の名前すべての押し離しを入れる。
    private static func wire(_ controller: GCController, to feed: GamepadFeed) {
        let profile = controller.physicalInputProfile
        let named = Dictionary(grouping: profile.buttons, by: { ObjectIdentifier($0.value) })
        for entries in named.values {
            guard let element = entries.first?.value else { continue }
            let buttons = entries.map { GamepadButton(rawValue: $0.key) }.sorted { $0.rawValue < $1.rawValue }
            element.pressedChangedHandler = { @Sendable _, _, pressed in
                for button in buttons { feed.send(pressed ? .pressed(button) : .released(button)) }
            }
        }
        profile.dpads[GCInputLeftThumbstick]?.valueChangedHandler = { @Sendable _, x, y in
            feed.send(tilt: SIMD2(x, -y))
        }
    }

    /// 付けた handler を外す。
    private static func unwire(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        for element in profile.buttons.values { element.pressedChangedHandler = nil }
        profile.dpads[GCInputLeftThumbstick]?.valueChangedHandler = nil
    }

    /// いま押されている釦と、いまの傾きを入れる。挿したときと、後から入り口が繋がったときに使う
    /// (handler は変わったときにしか呼ばれない)。
    private static func sendCurrent(of controller: GCController, to inboxes: [GamepadInbox]) {
        let profile = controller.physicalInputProfile
        let tilt = profile.dpads[GCInputLeftThumbstick].map { SIMD2($0.xAxis.value, -$0.yAxis.value) }
        let held = profile.buttons.filter { $0.value.isPressed }.map { GamepadButton(rawValue: $0.key) }
            .sorted { $0.rawValue < $1.rawValue }
        for inbox in inboxes {
            inbox.stick.send(tilt ?? .zero)
            for button in held { inbox.changes.send(.pressed(button)) }
        }
    }
}

/// 識別子 1 つぶんの中継。handler が届いたものを、繋がっている入れ物すべてへ入れる。
///
/// **どのスレッドから呼ばれてもよい** (handler は隔離の外で呼ばれうる)。入れ物は弱く持つ —
/// 入れ物を持つのは入り口 (``Gamepad``) で、閉じずに捨てられた入り口のぶんがここに溜まらない。
nonisolated final class GamepadFeed: Sendable {
    private let entries = Mutex<[Entry]>([])

    private struct Entry: Sendable {
        weak var inbox: GamepadInbox?
    }

    /// 繋がっている入れ物。
    var inboxes: [GamepadInbox] {
        entries.withLock { $0.compactMap(\.inbox) }
    }

    func add(_ inbox: GamepadInbox) {
        entries.withLock { list in
            list.removeAll { $0.inbox == nil || $0.inbox === inbox }
            list.append(Entry(inbox: inbox))
        }
    }

    func remove(_ inbox: GamepadInbox) {
        entries.withLock { list in list.removeAll { $0.inbox == nil || $0.inbox === inbox } }
    }

    func setState(_ state: SourceState) {
        for inbox in inboxes { inbox.setState(state) }
    }

    func send(_ change: GamepadChange) {
        for inbox in inboxes { inbox.changes.send(change) }
    }

    func send(tilt: SIMD2<Float>) {
        for inbox in inboxes { inbox.stick.send(tilt) }
    }
}

/// 実機のパッド 1 台ぶんの出どころ。中身は係 (``GamepadHub``) の中継へ繋ぐことだけである。
final class ControllerSource: GamepadSource {
    private let id: String
    private let hub: GamepadHub
    private weak var inbox: GamepadInbox?

    init(id: String, hub: GamepadHub) {
        self.id = id
        self.hub = hub
    }

    func start(into inbox: GamepadInbox) {
        self.inbox = inbox
        hub.subscribe(inbox, to: id)
    }

    func pump(into inbox: GamepadInbox) {}

    func stop() {
        if let inbox { hub.unsubscribe(inbox, from: id) }
    }
}
