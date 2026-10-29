// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization

@testable import MokumeNetwork

// 疑似のネットワーク (#3219)。受け口 (``DatagramAccepting``) と送り元の流れ (``DatagramFlow``) を
// socket なしで差し出し、受け入れ・受け・移り変わりの順序を検査が決める。
//
// **疑似が写すのは、本物の socket の検査が実測で固定している振る舞いだけ** — 閉じた流れの待っていた
// 受けは中身なしで返る (#2324)・取り消しの知らせは待ち行列を通って遅れて届く。実測そのものは本物の
// socket の検査 (`UDPPortTests` の `emptyDatagramIsAnEmptyString`・`networkFrameworkCutsDatagramsAt9216`)
// が見張る。疑似の前提が OS とずれたら、そちらが赤になる。

/// 疑似の送り元の流れ。検査が ``deliver(_:isFinal:)`` で datagram を 1 つずつ返す。
///
/// 手続きはすべて受け口の待ち行列の上で走る。``deliver(_:isFinal:)`` はその上で同期に返すので、
/// 返った後には受け口がその datagram を渡し終えている。
nonisolated final class FakeFlow: DatagramFlow, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``queue`` の上でだけ触る (``start(queue:ended:)`` の前は
    // 受け口が受け入れる前で、誰も触らない)。

    let sender: String
    private var queue: DispatchQueue?
    private var ended: (@Sendable () -> Void)?
    private var waiting: (@Sendable (Data?, Bool, Bool) -> Void)?
    private var isCancelled = false

    init(sender: String) { self.sender = sender }

    /// 受け口が閉じたか (黙りで閉じた・受け口ごと閉じた・終わりを名乗った空の後)。
    var cancelled: Bool { onQueue { isCancelled } }

    /// 受けを待っているか。
    var receiving: Bool { onQueue { waiting != nil } }

    func start(queue: DispatchQueue, ended: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.ended = ended
    }

    func receive(_ completion: @escaping @Sendable (Data?, Bool, Bool) -> Void) {
        waiting = completion
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        // Network.framework は、待っていた受けを中身なしで返し、`cancelled` を名乗る。どちらも
        // 待ち行列を通って遅れて届く (取り消した手続きの中では返らない)
        let pending = waiting
        waiting = nil
        queue?.async { [ended] in
            pending?(nil, false, false)
            ended?()
        }
    }

    /// datagram を 1 つ届ける。空の datagram は `content == nil` (Network.framework の形)。
    /// 受けを待っていなければ (閉じた後なら) 何もせず偽を返す。
    @discardableResult
    func deliver(_ bytes: [UInt8]?, isFinal: Bool = false) -> Bool {
        onQueue {
            guard let completion = waiting else { return false }
            waiting = nil
            completion(bytes.map { Data($0) }, isFinal, false)
            return true
        }
    }

    /// 失敗で終わる (待っていた受けが誤りつきで返り、`failed` を名乗る)。
    func fail() {
        onQueue {
            let pending = waiting
            waiting = nil
            pending?(nil, false, true)
            ended?()
        }
    }

    private func onQueue<Result>(_ body: () -> Result) -> Result {
        guard let queue else { return body() }
        return queue.sync(execute: body)
    }
}

/// 疑似の受け口。移り変わりは ``play(_:)`` の予定どおりに名乗り、受け入れは ``offer(_:)`` で 1 本ずつ。
nonisolated final class FakeAcceptor: DatagramAccepting, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``queue`` の上でだけ触る。

    let port: Int
    let host: String? = "127.0.0.1"
    let retryAfter: TimeInterval = 1
    private let queue: DispatchQueue
    private let changed: @Sendable (PortListener.Event) -> Void
    private let closed: @Sendable () -> Void
    private var accepting: (@Sendable (any DatagramFlow) -> Void)?
    private var isCancelled = false

    init(
        port: Int, queue: DispatchQueue, changed: @escaping @Sendable (PortListener.Event) -> Void,
        closed: @escaping @Sendable () -> Void
    ) {
        self.port = port
        self.queue = queue
        self.changed = changed
        self.closed = closed
    }

    /// 閉じたか。
    var cancelled: Bool { queue.sync { isCancelled } }

    func startAccepting(_ accepting: @escaping @Sendable (any DatagramFlow) -> Void) {
        // 本物 (``PortListener``) と同じく、開くのは待ち行列の上で後から
        queue.async { [self] in self.accepting = accepting }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        isCancelled = true
        accepting = nil
    }

    /// 開く試みの予定を順に名乗る。`ready` 以外は、本物の受け口が `failed` で閉じたときと同じく、
    /// 先に閉じた知らせ (送り元を外す) を出してから名乗る (``PortListener`` の `listenerChanged`)。
    func play(_ plan: [PortListener.Event]) {
        for event in plan {
            queue.sync {
                guard !isCancelled else { return }
                if case .ready = event {} else { closed() }
                changed(event)
            }
        }
    }

    /// 新しい送り元を受け入れさせる。閉じた後なら受け入れない。
    func offer(_ flow: FakeFlow) {
        queue.sync { accepting?(flow) }
    }

    /// 待ち行列に積まれた手続き (取り消しの知らせなど) を流し終えるまで待つ。
    func drain() { queue.sync {} }
}

/// 受け口を作る手続き (``DatagramListener/Acceptor``) を差し出し、作られた疑似の受け口を覚える。
nonisolated final class FakeNetwork: Sendable {
    let port: Int
    private let made = Mutex<[FakeAcceptor]>([])

    init(port: Int = 9000) { self.port = port }

    var acceptor: DatagramListener.Acceptor {
        { [self] queue, changed, closed in
            let acceptor = FakeAcceptor(port: port, queue: queue, changed: changed, closed: closed)
            made.withLock { $0.append(acceptor) }
            return acceptor
        }
    }

    /// 受け口が作られた数 (作る口が、渡した手続きで受け口を作ったかを見る)。
    var openedCount: Int { made.withLock { $0.count } }

    /// 受け口が作られたか。
    var opened: Bool { openedCount > 0 }

    /// 作られた受け口。受け口を作る前 (出どころを始める前) に読むのは検査の誤り。
    var listener: FakeAcceptor {
        guard let acceptor = made.withLock({ $0.last }) else {
            preconditionFailure("疑似の受け口がまだ作られていない (出どころを始める前に読んだ)")
        }
        return acceptor
    }

    /// `index` 番目の送り元の流れ。送り元の名乗りは番号ごとに別のポート。
    func flow(_ index: Int) -> FakeFlow {
        FakeFlow(sender: "127.0.0.1:\(50_000 + index)")
    }
}

/// 送り手 (``DatagramSender``) が見ることの予定 (#3219 の条件 4)。本物の繋ぎを作らずに、
/// 繋ぎの移り変わりと送信の完了を予定どおりの順で読ませる。
///
/// 送り手が繋ぎを捨てた後 (宛先の失敗) の送信は、本物と同じく新しい繋ぎで出る (検査が
/// 始めていない疑似の繋ぎ (``FakeLink``) を据える)。
nonisolated struct SendPlan: Sendable, CustomStringConvertible {
    enum Step: Sendable {
        /// 1 つ送り、完了が `error` で返る (`nil` は誤り無し)。
        case send(NWError?)
        /// 繋ぎが移る。
        case state(NWConnection.State)
        /// 時計を進める (秒)。
        case wait(TimeInterval)
        /// 区切り。何もしない (名乗りの列を区切りごとに数えるため)。
        case mark(String)
    }

    let name: String
    let steps: [Step]

    var description: String { name }

    /// 拒否 (`connection refused`)。
    static let refused = NWError.posix(.ECONNREFUSED)
}

/// ``SendPlan`` を 1 つの送り手で回した結果。区切りごとに、それまでの名乗りの行の数を持つ。
nonisolated struct SendPlanOutcome: Equatable, CustomStringConvertible {
    var lines: [String] = []
    var linesAtMark: [String: Int] = [:]

    var description: String {
        let marks = linesAtMark.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "名乗り \(lines.count) 行 (区切り \(marks.joined(separator: " ")))・全行: \(lines)"
    }
}

extension SendPlan {
    /// 予定を回す。同じ予定からは、同じ名乗りの列が返る。
    func run(host: String = "127.0.0.1", port: Int = 7000, confirmAfter: TimeInterval = 0.1) -> SendPlanOutcome {
        let told = Told()
        let clock = ManualClock(0)
        let sender = DatagramSender(
            host: host, port: port, confirmAfter: confirmAfter, now: clock.provider, warn: told.append)
        var current: FakeLink?
        var outcome = SendPlanOutcome()
        func connection() -> FakeLink {
            if let current { return current }
            let opened = FakeLink(host: host, port: port)
            sender.onQueue { sender.attach(opened) }
            current = opened
            return opened
        }
        for step in steps {
            switch step {
            case .send(let error):
                let sent = connection()
                let issued = clock.provider()
                sender.onQueue { sender.finished(sending: error, on: sent, issuedAt: issued) }
                // 宛先の失敗で、送り手は繋ぎを捨てる。次の送信は新しい繋ぎで出る
                if error != nil { current = nil }
            case .state(let state):
                let on = connection()
                sender.onQueue { sender.changed(to: state, on: on) }
                if case .failed = state { current = nil }
            case .wait(let seconds):
                clock.advance(by: seconds)
            case .mark(let label):
                outcome.linesAtMark[label] = told.lines.count
            }
        }
        outcome.lines = told.lines
        return outcome
    }
}

/// 疑似の送り手の繋ぎ (#3231)。送ったバイト列を覚え、完了を検査が決めた答えで返す。socket は開かない。
///
/// 手続きは送り手の待ち行列の上で走る。完了は ``send(_:completion:)`` の中で同期に返す (本物は待ち行列を
/// 通って遅れて返るが、送り手の読み替えは完了が返る順序だけを見る)。**疑似が写すのは、本物の socket の検査が
/// 実測で固定している振る舞いだけ** — 完了が「誤り無し」でも宛先に届いたとは限らず、拒否は次の送信の完了の
/// 誤りとして返る (`DatagramSenderLoopbackTests`)。疑似の前提が OS とずれたら、そちらが赤になる。
nonisolated final class FakeLink: DatagramLink, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``store`` の錠の中でだけ触る。

    let host: String
    let port: Int
    private struct Store {
        var sent: [[UInt8]] = []
        var started = false
        var cancelled = false
        var queue: DispatchQueue?
        var changed: (@Sendable (NWConnection.State) -> Void)?
    }
    private let store = Mutex(Store())
    private let answer: @Sendable (_ index: Int) -> NWError?

    /// - Parameter answer: `index` 番目 (0 から) の送信の完了。`nil` は誤り無し。
    init(host: String, port: Int, answer: @escaping @Sendable (Int) -> NWError? = { _ in nil }) {
        self.host = host
        self.port = port
        self.answer = answer
    }

    /// 送ったバイト列 (繋ぎを閉じた後も残る)。
    var sent: [[UInt8]] { store.withLock { $0.sent } }
    /// 始めたか。
    var started: Bool { store.withLock { $0.started } }
    /// 閉じたか。
    var cancelled: Bool { store.withLock { $0.cancelled } }

    func start(queue: DispatchQueue, changed: @escaping @Sendable (NWConnection.State) -> Void) {
        store.withLock {
            $0.started = true
            $0.queue = queue
            $0.changed = changed
        }
    }

    func send(_ bytes: [UInt8], completion: @escaping @Sendable (NWError?) -> Void) {
        let index = store.withLock { store in
            defer { store.sent.append(bytes) }
            return store.sent.count
        }
        completion(answer(index))
    }

    func cancel() {
        store.withLock { $0.cancelled = true }
    }

    /// 繋ぎが移ったと名乗る。送り手の待ち行列の上で、同期に返す。始めていなければ何もしない。
    func move(to state: NWConnection.State) {
        let (queue, changed) = store.withLock { ($0.queue, $0.changed) }
        guard let queue, let changed else { return }
        queue.sync { changed(state) }
    }
}

/// 繋ぎを作る手続き (``DatagramSender/Connect``) を差し出し、作られた疑似の繋ぎを覚える。
nonisolated final class FakeWire: Sendable {
    private let made = Mutex<[FakeLink]>([])
    private let answer: @Sendable (_ link: Int, _ index: Int) -> NWError?

    /// - Parameter answer: `link` 番目の繋ぎの `index` 番目の送信の完了。`nil` は誤り無し。
    init(answer: @escaping @Sendable (Int, Int) -> NWError? = { _, _ in nil }) { self.answer = answer }

    var connect: DatagramSender.Connect {
        { [self] host, port in
            let link = made.withLock { links in
                let number = links.count
                let link = FakeLink(host: host, port: port) { [answer] index in answer(number, index) }
                links.append(link)
                return link
            }
            return link
        }
    }

    /// 作られた繋ぎ (作られた順)。
    var links: [FakeLink] { made.withLock { $0 } }

    /// どの繋ぎへ送ったか (繋ぎの宛先と、送ったバイト列)。
    var sent: [[UInt8]] { links.flatMap(\.sent) }
}
