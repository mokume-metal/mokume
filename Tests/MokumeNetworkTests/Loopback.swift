// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

// 同じ機械の中で送って受ける検査が共有する道具。通信は 127.0.0.1 だけで行う。
//
// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる
// (AGENTS.md「待ちを含む検査を書く」)。

/// 期限まで、条件が満ちるのを待つ。満ちなければ偽。
func until(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// フレームを回すように取り出しを続け、`count` 個届くまで (か期限まで) 集める。
///
/// `log` を渡せば、読めた数と待った秒数を数える (読まれなかった回の名乗りの材料 — #3001)。どの通が読まれ
/// なかったかは分からない (`label` の受け口の列として数える)。
func collect(
    _ port: TextPort, count: Int, within seconds: TimeInterval = 5, label: String = "送り",
    log: SendLog? = nil
) async -> [String] {
    var received: [String] = []
    let started = Date()
    _ = await until(seconds) {
        port.supply()
        received += port.messages
        return received.count >= count
    }
    log?.record(
        label: label, expected: count, heard: min(received.count, count), missing: nil, replacements: 0,
        heardAfterReplacement: 0, waited: Date().timeIntervalSince(started), limit: seconds)
    return received
}

/// 受けた文字列を作例のスケッチと同じく読んだ結果 (数は大きさを置き換え、`hit` を数える)。
struct TextOutcome: Equatable {
    var size: Float = 0.5
    var hits = 0

    init(size: Float, hits: Int) {
        self.size = size
        self.hits = hits
    }

    init(_ messages: [String]) {
        for text in messages {
            if let value = Float(text) {
                size = value
            } else if text == "hit" {
                hits += 1
            }
        }
    }
}

/// 送る文字列の台本。大きさを動かし、当たりを数える。
let textScript = ["0.25", "hit", "0.75", "fade", "hit"]

/// 期限まで `condition` が満ちるのを待ち、満ちなければ `what` と `detail` を名乗って 1 つで止まる
/// (`#require`・#2945)。
///
/// 期限で偽を言うだけだと、赤の文面から何も読み分けられない。**期限は延ばさず、待ちの中で口を閉じて
/// 開き直さない** — 原因が分かっていないので、救うと次の 1 回で読み分ける材料が消える。
/// 止まると、後ろの期待 (相手側の様子など) は見られない。相手側の手がかりが減る代わりに、後の期待へ
/// 連鎖しない。
func requireWait(
    _ what: String, within seconds: TimeInterval = 5, detail: () -> String,
    until condition: () -> Bool
) async throws {
    let met = await until(seconds) { condition() }
    try #require(met, "\(what) (\(detail())・期限 \(seconds) 秒)")
}

/// 口の中の移り変わりの跡を、名乗りに載せる文にする。跡を読めない出どころなら空。
private func traceText(_ tracing: AnyObject?) -> String {
    guard let trace = (tracing as? any EventTracing)?.trace else { return "" }
    return "・移り変わり \(trace.count) 回・最後: \(trace.last ?? "なし")"
}

/// 口 (受け口・繋ぎに行く側) の状態が `wanted` になるのを、期限まで待つ。
///
/// 期限までに `wanted` にならなければ、次を名乗って 1 つで止まる (`#require`・#2945)。
/// - **状態** (``SourceState``)
/// - **口の中の移り変わりの数と最後のもの** (`tracing`。``EventTrace``)。知らせは同じ種類を受けられるまで
///   1 度しか言わないので、`told` の行だけでは「使用中が続いている」「開き直しが止まった」「手放す前の 1 行が
///   残っているだけ」を分けられない。**数が増え続けるなら開き直しが続いていて、増えないなら止まっている。**
///   ただし、開き直しの試みそのもの (受け口を作り直したか) は見えない — 見えるのは受けた移り変わりだけ
/// - **`told` に書かれた全行。他の口 (相手側・送り手) の行も混ざる**ので、行の頭のラベルで見分ける
///
/// - Parameters:
///   - told: 口の `warn:` に渡したもの。
///   - tracing: 口の出どころ (`port.source`)。``EventTracing`` でなければ移り変わりは載せない。
func requireState(
    _ wanted: SourceState = .running, what: String = "受け口", told: Told,
    within seconds: TimeInterval = 5, tracing: AnyObject? = nil, state: () -> SourceState
) async throws {
    try await requireWait(
        "\(what)が \(wanted.rawValue) にならなかった", within: seconds,
        detail: {
            let trace = traceText(tracing)
            return "状態: \(state().rawValue)\(trace)・同じ told の全行: \(told.lines)"
        },
        until: { state() == wanted })
}

/// 口が `text` を含む知らせを `count` 回言うのを、期限まで待つ (`exactly` なら丁度、でなければ以上)。
/// 言わなければ、状態と移り変わりと `told` の全行を名乗って止まる (``requireState`` と同じ)。
func requireTold(
    containing text: String, count: Int = 1, exactly: Bool = true, told: Told,
    within seconds: TimeInterval = 5, tracing: AnyObject? = nil, state: () -> SourceState
) async throws {
    try await requireWait(
        "「\(text)」を含む知らせが \(exactly ? "" : "少なくとも ")\(count) 回出なかった", within: seconds,
        detail: {
            let trace = traceText(tracing)
            return "状態: \(state().rawValue)\(trace)・同じ told の全行: \(told.lines)"
        },
        until: {
            let seen = told.count(containing: text)
            return exactly ? seen == count : seen >= count
        })
}

/// 受け始めるまで待って、実際に開いたポートを返す。`told` は受け口の `warn:` に渡したもの。
func boundPort(of server: TextPort, source: StreamSource, told: Told) async throws -> Int {
    try await requireState(told: told, tracing: source) { server.state }
    return try #require(source.boundPort)
}

/// フレームを回すように取り出しを続け、繋いでいる相手の数が `count` になるまで (か期限まで) 待つ。
func clients(_ server: TextPort, reach count: Int) async -> Bool {
    await until {
        server.supply()
        return server.connected == count
    }
}

/// 検査の側の相手の繋ぎの状態。**1 つの値で読む** — 「まだ繋がっていない」と「名乗った」を別々に
/// 読むと、間に書き換えが入って食い違う。
nonisolated enum PeerState: Equatable, Sendable {
    /// 繋ぎに行っている途中 (まだ何も名乗っていない)。
    case connecting
    /// 繋がった。
    case ready
    /// 繋ぎが成り立たないと名乗った (`waiting`・`failed` と、その理由)。
    case trouble(String)

    var text: String {
        switch self {
        case .connecting: "繋ぎの途中"
        case .ready: "繋がった"
        case .trouble(let reason): reason
        }
    }
}

/// 受け口へ繋ぎに行く、検査の側の相手 (``StreamClient``・``BrowserSocket``)。
nonisolated protocol LoopbackPeer: AnyObject, Sendable {
    /// 繋ぎの状態。
    var state: PeerState { get }
    /// 繋ぎを切る。
    func close()
}

extension LoopbackPeer {
    /// 繋がったか。
    var isReady: Bool { state == .ready }
}

nonisolated extension NWConnection.State {
    /// 検査の側の相手の状態への読み替え。繋がった後の `waiting`・`failed` は、繋がったまま読む
    /// (切れた相手は、受け口の数が示す)。
    fileprivate func peerState(after current: PeerState) -> PeerState {
        switch self {
        case .ready: return .ready
        case .waiting(let error): return current == .ready ? current : .trouble("waiting (\(error))")
        case .failed(let error): return current == .ready ? current : .trouble("failed (\(error))")
        default: return current
        }
    }
}

/// 受け口へ繋ぎに行く相手の束。**全員が繋がるまで待ち、繋がらない相手を、猶予を置いて新しい相手に
/// 替える** (#2940)。
///
/// 全段が並走する CI で、受け口へ繋ぎに行く検査の側の相手が 10〜20 秒たっても繋がらず、後の期待が
/// 連鎖して外れたことが 2 回あった (同じ suite の直後の検査は普通に繋がっていた)。**止まった繋ぎが
/// `waiting` なのか `preparing` のままなのか、なぜ止まったのかは、確かめていない** (CI のログには相手の
/// 状態が残っていなかった)。UDP の送り元が `Address already in use` で `waiting` のまま回復しなかった
/// #2910 と同じ形の見込みで、製品の ``ClientSource`` も `waiting` を自分で閉じて張り直している。
///
/// 替え方は、状態を問わない。**繋がっていない相手は、猶予 (`within` を替える回数 + 1 で割った間) が
/// 過ぎたら、古い相手を閉じてから新しい相手に替える** (1 人あたり `replacements` 回まで)。猶予を置くのは、
/// 状態が数秒続くだけで回復する場合にも、替えずに待つ余地を残すため。受け口の数との照合は厳密
/// (`==`) だが、古い相手を閉じてから替えるので、数は戻る。UDP の台帳 (読む前の繋ぎは黙りで閉じない —
/// #2937) とは違い、受け口が古い相手の繋ぎを持ち続けない。全員が繋がり、かつ受け口の数が人数に
/// 一致するまで抜けない (閉じた古い相手が受け口の数に一瞬残る隙間で、先へ進まないため)。
///
/// 待ちの上限が 10 秒なのは、以前の `clients(_, reach:)` の 5 秒に、替える分の猶予 (3 回 × 約 2.5 秒) を
/// 載せるため。5 秒のままでは、1 回替えて新しい相手の繋ぎを待つ時間が残らない。
///
/// 相手は ``subscript(_:)`` で読む。**``reach(on:replacements:within:)`` の後に読む** — 替えると
/// 同じ番号の相手が別のものになる。
final class PeerGroup<Peer: LoopbackPeer> {
    private(set) var peers: [Peer]
    private(set) var replaced = 0
    private let make: () -> Peer

    /// `count` 人の相手を作って繋ぎに行かせる。
    init(_ count: Int = 1, make: @escaping () -> Peer) {
        self.make = make
        peers = (0..<count).map { _ in make() }
    }

    subscript(index: Int) -> Peer { peers[index] }

    /// 束の全員を切る。替えた後の相手も、替えて閉じた相手の分も、これで足りる。
    func closeAll() { for peer in peers { peer.close() } }

    /// 受け口が束の人数を数え、全員が繋がるまで (か期限まで) 待つ。
    ///
    /// 数えない理由を 1 つで名乗って止まる (`#require`): 受け口の状態・数・替えた回数と、相手ごとの
    /// 状態 (名乗った理由を含む)。受け口側の原因か相手側の原因かは、これで読み分ける。
    func reach(on server: TextPort, replacements: Int = 3, within seconds: TimeInterval = 10)
        async throws
    {
        let expected = peers.count
        let patience = seconds / Double(replacements + 1)
        var attempts = [Int](repeating: 1, count: expected)
        var since = [Date](repeating: Date(), count: expected)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            server.supply()
            if server.connected == expected, peers.allSatisfy(\.isReady) { return }
            let now = Date()
            for index in peers.indices
            where !peers[index].isReady && attempts[index] <= replacements
                && now.timeIntervalSince(since[index]) >= patience
            {
                attempts[index] += 1
                since[index] = now
                replaced += 1
                peers[index].close()
                peers[index] = make()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        server.supply()
        let ready = peers.allSatisfy(\.isReady)
        try #require(
            server.connected == expected && ready,
            "\(expected) 人のうち、受け口が数えたのは \(server.connected) 人 (受け口の状態: \(server.state)・替えたのは \(replaced) 回・期限 \(seconds) 秒)。相手の様子: \(peers.enumerated().map { "#\($0.offset) \($0.element.state.text)" })"
        )
    }
}

/// 数の列を、連なりを畳んで昇順に書く (`[2…5, 7, 9…69]`)。揺れない順で名乗るため。
nonisolated func rangesText(_ numbers: [Int]) -> String {
    let sorted = Array(Set(numbers)).sorted()
    var parts: [String] = []
    var index = 0
    while index < sorted.count {
        var end = index
        while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
        parts.append(end == index ? "\(sorted[index])" : "\(sorted[index])…\(sorted[end])")
        index = end + 1
    }
    return "[" + parts.joined(separator: ", ") + "]"
}

/// ``readWithin(_:_:)`` の答えの置き場。
nonisolated final class Answer<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    var current: Value? { value.withLock { $0 } }
}

/// 期限つきで読む。**待つ側が期限を持ち、越えたら諦めて `nil` を返す** (#3001)。
///
/// 受け口の `tally`・`connectionCount` は、受け口の待ち行列の上で `sync` で読む。待ち行列が詰まると、
/// 名乗る前に検査が止まる。別のスレッドで読み、期限までに答えなければ諦める (読みそびれたスレッドは、
/// 待ち行列が空いたときに終わる)。
func readWithin<Value: Sendable>(
    _ seconds: TimeInterval, _ read: @escaping @Sendable () -> Value
) async -> Value? {
    let answer = Answer<Value>()
    DispatchQueue.global().async { answer.set(read()) }
    _ = await until(seconds) { answer.current != nil }
    return answer.current
}

/// 受け口の様子。**ある 1 つの時点の写し** — 名乗りは、送り手の様子と同じ時点で撮る。
nonisolated struct ReceiverView: Sendable {
    var state: SourceState
    /// 受け口の移り変わりの跡。読めない出どころなら `nil`。
    var trace: EventTrace?
    /// 送り元の出入りの数と持つ数。受け口の待ち行列が期限までに答えなかったら `nil`。
    var tally: SenderTally?
    var connections: Int?
    /// 受け口の知らせ (`told`)。送り手の名乗り (`Could not send to …`) は送り手の行なので除く。
    var told: [String]
    /// 待ち行列を待った期限 (秒)。
    var patience: TimeInterval
    /// 受け口を読めない出どころ (``DatagramSource`` でない) だった。
    var unreadable = false

    var accepted: Int? { tally?.accepted }

    var text: String {
        if unreadable { return "\(state.rawValue)・出どころを読めない" }
        var parts = [state.rawValue]
        if let trace { parts.append("移り変わり \(trace.count) 回・最後: \(trace.last ?? "なし")") }
        if let tally, let connections {
            parts.append(
                "受け入れ \(tally.accepted)・黙りで閉じた \(tally.closedIdle)・終わって外れた \(tally.ended)・持つ数 \(connections)")
        } else {
            parts.append(
                "受け口の待ち行列が \(String(format: "%.1f", patience)) 秒答えなかった (受け入れ・持つ数は読めない)")
        }
        parts.append(
            told.isEmpty
                ? "受け口の知らせは 0 行" : "受け口の知らせ \(told.count) 行 \(told.prefix(5).map { String($0.prefix(140)) })")
        return parts.joined(separator: "・")
    }
}

/// 受け口の様子を撮る。**待ち行列の上の読み (`read`) は期限つき** (``readWithin(_:_:)``)。
func receiverView(
    _ state: SourceState, tracing: AnyObject?, told: Told, within seconds: TimeInterval = 3,
    read: @escaping @Sendable () -> (SenderTally, Int)
) async -> ReceiverView {
    let answered = await readWithin(seconds, read)
    return ReceiverView(
        state: state, trace: (tracing as? any EventTracing)?.trace, tally: answered?.0,
        connections: answered?.1,
        told: told.lines.filter { !$0.hasPrefix("Could not send to") }, patience: seconds)
}

/// 受け口 (``DatagramSource``) の様子を撮る。
func receiverView<Message: Sendable>(
    _ state: SourceState, _ source: DatagramSource<Message>, told: Told, within seconds: TimeInterval = 3
) async -> ReceiverView {
    await receiverView(state, tracing: source, told: told, within: seconds) {
        (source.tally, source.connectionCount)
    }
}

/// 素の socket から別の宛名で 1 通送り、`arrived` が真になるのを `seconds` 秒まで待つ。名乗りの材料で、救いには
/// 使わない。
func probeWithRawSocket(
    port: Int, packet: [UInt8], within seconds: TimeInterval = 3, arrived: () -> Bool
) async -> Bool {
    guard let raw = try? RawDatagramSocket() else { return false }
    defer { raw.release() }
    _ = raw.send(packet, to: port)
    return await until(seconds) { arrived() }
}

/// 前提が満たされなかったときの、受け口側の読み口 (``requireSent(_:_:log:landing:)``)。
struct Landing {
    /// 受け口の様子を撮る。
    var receiver: () async -> ReceiverView
    /// 素の socket から 1 通送って、読まれたか。
    var probe: () async -> Bool
}

/// OSC の入り口 `osc` の読み口。素の socket の 1 通は `/probe` の OSC を `port` へ送る。
func landing(of osc: OSCPort, port: Int, told: Told) -> Landing {
    Landing(
        receiver: {
            guard let source = osc.source as? NetworkOSCSource else {
                return ReceiverView(
                    state: osc.state, trace: nil, tally: nil, connections: nil, told: [], patience: 0,
                    unreadable: true)
            }
            return await receiverView(osc.state, source, told: told)
        },
        probe: {
            await probeWithRawSocket(
                port: port, packet: (try? Wire.encoded(OSCMessage("/probe", 1))) ?? []
            ) {
                osc.supply()
                return osc.messages.contains { $0.address == "/probe" }
            }
        })
}

/// 文字列の入り口 (UDP) `udp` の読み口。素の socket の 1 通は `probe` の 5 文字を `port` へ送る。
func landing(of udp: TextPort, port: Int, told: Told) -> Landing {
    Landing(
        receiver: {
            guard let source = udp.source as? DatagramSource<String> else {
                return ReceiverView(
                    state: udp.state, trace: nil, tally: nil, connections: nil, told: [], patience: 0,
                    unreadable: true)
            }
            return await receiverView(udp.state, source, told: told)
        },
        probe: {
            await probeWithRawSocket(port: port, packet: Array("probe".utf8)) {
                udp.supply()
                return udp.messages.contains("probe")
            }
        })
}

/// 送り手の様子を数える記録 (#3001)。送り元の補助 (``sendAndCollect(_:expecting:to:senders:replacements:within:label:log:makeSender:)``・
/// `OSCPortTests` の `sendNumberedBurst`・``collect(_:count:within:label:log:)``) が、前提の段で見たことを足す。
///
/// 補助は読まれなかった番号があっても、期限で読まれた分だけを返す (救わない・期限を延ばさない)。
/// 呼ぶ側は ``requireSent(_:_:log:landing:)`` に渡して、前提が満たされなかった回の名乗りに送り手の様子を
/// 載せる。**送り手の名乗りの行は、受け口の知らせ (`told`) と混ぜずに、送り元の位置 (`label#番号`) つきで
/// ここで数える。** 足す呼び出しが複数回あっても (台帳を足す段は回ごとに呼ぶ)、同じ記録へ足せる。
///
/// 送り元ごとの跡 (``SendTrace``: 出した数・誤り無しの完了・誤りの完了・最後の状態) は、名乗る時点で
/// 送り元から読む (``watch(_:index:trace:)``)。名乗りは、読めなかった側と読めた側に分けて数える。
nonisolated final class SendLog: Sendable {
    /// 送り元の位置。`label` は 1 回の補助の呼び (OSC なら宛名 `/from`・UDP なら `列`)、`index` はその中の番号。
    struct Slot: Hashable, Comparable {
        let label: String
        let index: Int
        static func < (lhs: Slot, rhs: Slot) -> Bool { (lhs.label, lhs.index) < (rhs.label, rhs.index) }
    }

    private struct Group {
        var expected = 0
        var heard = 0
        /// 読まれなかった番号。どの通かが分からない (文字列の列) なら `nil`。
        var missing: [Int]? = []
        var replacements = 0
        var heardAfterReplacement = 0
    }

    private struct State {
        var order: [String] = []
        var groups: [String: Group] = [:]
        var waited: TimeInterval = 0
        var limit: TimeInterval = 0
        var complaints: [Slot: [String]] = [:]
        var traces: [Slot: TraceReader] = [:]
    }

    /// 送り元の跡を読む口。**読むのは名乗る側 (検査のスレッド) だけ**なので、`@unchecked Sendable` で持つ。
    private final class TraceReader: @unchecked Sendable {
        let read: () -> SendTrace?
        init(_ read: @escaping () -> SendTrace?) { self.read = read }
    }
    private let state = Mutex(State())

    /// 送り元の名乗り (`Could not send to …`) を 1 行足す。替えた後の古い送り元の遅れた名乗りも数える。
    func complain(_ line: String, label: String, index: Int) {
        state.withLock { $0.complaints[Slot(label: label, index: index), default: []].append(line) }
    }

    /// 送り元の跡を読む口を据える。替えたら、新しい送り元の口で置き換える (名乗る時点で読む)。
    func watch(_ label: String = "送り", index: Int = 0, trace: @escaping () -> SendTrace?) {
        let reader = TraceReader(trace)
        state.withLock { $0.traces[Slot(label: label, index: index)] = reader }
    }

    /// 送り元 `sender` の跡を読む口を据える。跡を持たない送り元 (作り物) は「様子を読めない」と名乗る。
    func watch(_ label: String = "送り", index: Int = 0, sender: any DatagramSending) {
        watch(label, index: index) { (sender as? SendTracing)?.sendTrace }
    }

    /// 補助 1 回分の結果を足す。`missing` は読まれなかった番号 (どの通かが分からなければ `nil`)。
    /// `heardAfterReplacement` は、送り元を替えた後に読まれた数。**古い送り元から遅れて届いた分も入る**
    /// (受け口からは出どころを区別できない)。
    func record(
        label: String, expected: Int, heard: Int, missing: [Int]?, replacements: Int,
        heardAfterReplacement: Int, waited: TimeInterval, limit: TimeInterval
    ) {
        state.withLock {
            if $0.groups[label] == nil { $0.order.append(label) }
            var group = $0.groups[label] ?? Group()
            group.expected += expected
            group.heard += heard
            if let missing, let known = group.missing { group.missing = known + missing } else { group.missing = nil }
            group.replacements += replacements
            group.heardAfterReplacement += heardAfterReplacement
            $0.groups[label] = group
            $0.waited += waited
            $0.limit += limit
        }
    }

    /// 待った秒数と期限。呼びを重ねたときは、どちらも合計。
    var waitText: String {
        state.withLock {
            "待った \(String(format: "%.1f", $0.waited)) 秒/期限 \(String(format: "%.1f", $0.limit)) 秒"
        }
    }

    private static func text(of trace: SendTrace?) -> String {
        guard let trace else { return "様子を読めない送り元" }
        return "出 \(trace.issued)・誤り無し \(trace.completed)・誤り \(trace.failed)・最後 \(trace.state ?? "知らせ無し")"
    }

    /// 送り手側の様子。**読む時点の写し** — 名乗る側が、受け口の様子と同じ時点で呼ぶ。
    ///
    /// 並びは揺れない順 (宛名・番号の昇順。同じ様子の送り元は数でまとめる)。**名乗りが 0 行なら、そうと言う**
    /// (黙って出ない送り元の形)。
    var senderText: String {
        state.withLock { state in
            var parts: [String] = []
            for label in state.order {
                guard let group = state.groups[label] else { continue }
                var line = "\(label): 読めたのは \(group.heard)/\(group.expected)"
                if let missing = group.missing {
                    if !missing.isEmpty {
                        let spoke = missing.filter { state.complaints[Slot(label: label, index: $0)] != nil }
                        let silent = missing.filter { state.complaints[Slot(label: label, index: $0)] == nil }
                        line +=
                            "・読めなかった \(missing.count) 本 \(rangesText(missing))・うち名乗った \(rangesText(spoke))・名乗らずに黙っている \(rangesText(silent))"
                    }
                } else if group.heard < group.expected {
                    line += "・読めなかった \(group.expected - group.heard) 通 (どの通かは分からない)"
                }
                line += "・替えた \(group.replacements) 回・替えた後に読めた \(group.heardAfterReplacement) 本"
                parts.append(line)
            }
            parts.append("(替えた後に読めた数は、古い送り元から遅れて届いた分も含み、出どころは区別できない)")

            // 送り元の跡: 読めなかった側と読めた側で、同じ様子の送り元を数える
            var missed: [String: Int] = [:]
            var heard: [String: Int] = [:]
            var unsorted: [String: Int] = [:]
            for (slot, trace) in state.traces.sorted(by: { $0.key < $1.key }) {
                let text = Self.text(of: trace.read())
                switch state.groups[slot.label]?.missing {
                case .some(let missing) where missing.contains(slot.index): missed[text, default: 0] += 1
                case .some: heard[text, default: 0] += 1
                case .none: unsorted[text, default: 0] += 1
                }
            }
            func histogram(_ counts: [String: Int]) -> String {
                counts.sorted { $0.key < $1.key }.map { "{\($0.key)}×\($0.value)" }.joined(separator: " ")
            }
            if !missed.isEmpty { parts.append("読めなかった側の送り元の様子 \(histogram(missed))") }
            if !heard.isEmpty { parts.append("読めた側の送り元の様子 \(histogram(heard))") }
            if !unsorted.isEmpty { parts.append("送り元の様子 \(histogram(unsorted))") }

            let total = state.complaints.values.reduce(0) { $0 + $1.count }
            if total == 0 {
                parts.append("名乗りは 0 行 (黙っている)")
            } else {
                let owners = Dictionary(grouping: state.complaints.keys, by: \.label)
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)\(rangesText($0.value.map(\.index)))" }
                let examples = Set(state.complaints.values.joined()).sorted().prefix(2).map { String($0.prefix(110)) }
                parts.append("名乗った送り元 \(owners.joined(separator: " "))・名乗り \(total) 行 例 \(examples)")
            }
            return parts.joined(separator: "。")
        }
    }
}

/// `body` が止まるときの名乗りを集める。止まらなければ空。**名乗りの検査**が使う (`withKnownIssue` で受ける)。
func said(_ body: () async throws -> Void) async throws -> String {
    let text = Mutex("")
    try await withKnownIssue {
        try await body()
    } matching: { issue in
        text.withLock { $0 = issue.comments.map(\.rawValue).joined(separator: "\n") }
        return true
    }
    return text.withLock { $0 }
}

/// 送り元から送った前提 (送った番号・列が読まれた) が満たされたことを求める。**満たされなければ、受け口側と
/// 送り手側の様子を名乗って 1 つで止まる** (`#require`・#3001)。
///
/// 名乗りは、`what` (何が満たされなかったか)・待った秒数と期限・送り手の様子 (`log`)・受け口の様子
/// (``Landing/receiver``)・**素の socket から 1 通送って、止まる時点の受け口が新しい送り元を受けられたか**
/// (``Landing/probe``)。送り手と受け口は同じ時点で撮り (受け口の待ち行列が答えないときだけ、その待ちぶん
/// ずれる)、受け口は 1 通の前後に分けて名乗る。1 通の後で受け入れの数が増えたかも名乗る — 読まれても、
/// 受け入れが増えなければ別の繋ぎで渡されたのであって、新しい送り元を受けたとは言えない。
///
/// **この 1 通は名乗りの材料で、救いには使わない。** 読めても検査は止まる。期限は延ばさず、受け口を
/// 閉じて開き直さず、名乗らない送り元も替えない (原因が分かっていないので、救うと次の 1 回で読み分ける
/// 材料が消える — #2945 と同じ。#2978 の判断の材料になる)。
///
/// **この 1 通で分からないこと**: 1 通は、多くの送り元が一度に来た後の静かなときに送る。一度に来たときだけ
/// 受け口で落ちる形は、この 1 通では分からない (名乗りの文にも書く)。受け入れの数の差には、遅れて届いた
/// 別の送り元の分も入る。
///
/// - Parameters:
///   - ok: 前提が満たされたか。
///   - what: 満たされなかったことの 1 文 (例: 「送り元 54 本のうち読めたのは 1 本」)。
func requireSent(
    _ ok: Bool, _ what: @autoclosure () -> String, log: SendLog, landing: Landing
) async throws {
    if ok { return }
    // 送り手と受け口は同じ時点で撮り、その後に素の socket の 1 通を送る (送ると受け入れの数が 1 つ増える)
    let senders = log.senderText
    let before = await landing.receiver()
    let probed = await landing.probe()
    let after = await landing.receiver()

    let delta: Int? = {
        guard let was = before.accepted, let now = after.accepted else { return nil }
        return now - was
    }()
    let probeText: String
    switch (probed, delta) {
    case (true, let delta?) where delta >= 1: probeText = "読めた・受け入れ +\(delta) (新しい送り元を受けられた)"
    case (true, let delta?): probeText = "読めたが受け入れは増えていない (差 \(delta)。別の繋ぎで渡された)"
    case (true, nil): probeText = "読めた (受け入れの数は読めない)"
    case (false, _): probeText = "読めなかった (受け口が 3 秒のうちに新しい送り元の datagram を渡さなかった)"
    }
    try #require(
        ok,
        "\(what()) (\(log.waitText))。送り手: \(senders)。受け口 (1 通の前): \(before.text)。素の socket の 1 通: \(probeText)。受け口 (1 通の後): \(after.text)。注: この 1 通は、送り元が一度に来た後の静かなときに送る。一度に来たときだけ受け口で落ちる形は、この 1 通では分からない。受け入れの数の差には、遅れて届いた別の送り元の分も入る"
    )
}

/// 1 つの送り元から datagram の列を送り、`count` 通が届くまで (か期限まで) 集めて、読まれた文字列を返す。
///
/// **送った datagram が全部読まれる前提を置かない** (#2910・#2940)。送り元の繋ぎが `Address already
/// in use` で `waiting` のまま回復しないと、送った列は 1 通も出ない。**送れないと名乗り、まだ 1 通も
/// 読まれていない送り元は、猶予 (`within` を替える回数 + 1 で割った間) の後に、新しい送り元に替えて列を
/// 最初から送り直す**。1 通でも読まれた後は替えない — 列の途中から送り直すと、順や数が崩れる。名乗らずに
/// 読まれない送り元も替えない (読みが遅れているだけのことがあり、足すと台帳が目安から下がらなくなる —
/// #2937)。替えた古い送り元は閉じ、その遅れた名乗りは数えない。
///
/// 送り元は `senders` の末尾へ足す。呼ぶ側が検査の終わりに閉じる。名乗りは送り元の側の話なので、
/// 受け口の知らせ (`told`) には流さず、`log` に数える (替えた回数・替えた後に読めた数・送り元の跡も。
/// 読まれなかった回は、呼ぶ側が ``requireSent(_:_:log:landing:)`` で名乗る — #3001)。
func sendAndCollect(
    _ datagrams: [[UInt8]], expecting count: Int, to port: TextPort,
    senders: inout [any DatagramSending], replacements: Int = 3, within seconds: TimeInterval = 10,
    label: String = "列", log: SendLog = SendLog(),
    makeSender: (_ warn: @escaping @Sendable (String) -> Void) -> any DatagramSending
) async throws -> [String] {
    let stuck = Mutex(false)
    let current = Mutex(1)
    var attempt = 1
    let patience = seconds / Double(replacements + 1)
    let started = Date()
    func open() -> any DatagramSending {
        let mine = attempt
        let sender = makeSender { line in
            log.complain(line, label: label, index: 0)
            guard current.withLock({ $0 }) == mine else { return }
            stuck.withLock { $0 = true }
        }
        log.watch(label, sender: sender)
        for datagram in datagrams { sender.send(datagram) }
        return sender
    }
    senders.append(open())
    let index = senders.count - 1
    var received: [String] = []
    var since = Date()
    let deadline = Date().addingTimeInterval(seconds)
    while received.count < count, Date() < deadline {
        port.supply()
        received += port.messages
        if received.isEmpty, attempt <= replacements, stuck.withLock({ $0 }),
            Date().timeIntervalSince(since) >= patience
        {
            attempt += 1
            current.withLock { $0 = attempt }
            stuck.withLock { $0 = false }
            since = Date()
            senders[index].stop()
            senders[index] = open()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let heard = min(received.count, count)
    log.record(
        label: label, expected: count, heard: heard, missing: nil, replacements: attempt - 1,
        heardAfterReplacement: attempt > 1 ? heard : 0, waited: Date().timeIntervalSince(started),
        limit: seconds)
    return received
}

/// 127.0.0.1 のポートへ、素の BSD socket から datagram を送る相手 (他のアプリの代わり)。
///
/// **1 つの socket から送るので、受け口からは 1 つの送り元に見える。** 間を空けずに続けて送れば、
/// 後ろの datagram は受け口の同じ繋ぎに積まれている。送る上限 (`SO_SNDBUF`) を広げてあり、
/// macOS の既定 (`net.inet.udp.maxdgram` の 9216 バイト) を超える datagram も送れる —
/// ``DatagramSender`` は超えると `Message too long` で送れない。
nonisolated final class RawDatagramSocket: Sendable {
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw PortHolder.Failure(call: "socket", code: errno) }
        var size: Int32 = 1 << 20
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            let code = errno
            close(descriptor)
            throw PortHolder.Failure(call: "setsockopt", code: code)
        }
        self.descriptor = descriptor
    }

    /// 1 つの datagram として送る。送れたバイト数を返す (送れなければ -1)。
    func send(_ bytes: [UInt8], to port: Int) -> Int {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, buffer.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// 送り元のポート。**1 度送った後に読む** (送るまでは OS が番号を決めていない)。
    var port: Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func release() { close(descriptor) }
}

/// 127.0.0.1 のポートへ TCP で繋ぐ相手 (`nc` の代わり)。届いたバイト列を溜める。
nonisolated final class StreamClient: LoopbackPeer, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.client")
    private let connection: NWConnection
    private let bytes = Mutex<[UInt8]>([])
    private let link = Mutex(PeerState.connecting)
    private let ended = Mutex(false)

    init(port: Int) {
        connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            self?.link.withLock { $0 = state.peerState(after: $0) }
        }
        connection.start(queue: queue)
        receive()
    }

    /// 繋ぎの状態 (``LoopbackPeer``)。
    var state: PeerState { link.withLock { $0 } }
    /// 届いたバイト列を文字列にしたもの。
    var received: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    func send(_ text: String) { send(Array(text.utf8)) }

    func send(_ raw: [UInt8]) {
        connection.send(content: Data(raw), completion: .idempotent)
    }

    /// 送る向きを閉じる (送ったものの後に、終わりの印が届く)。受ける向きは開いたまま。
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { bytes.withLock { $0 += content } }
            if isComplete || error != nil {
                ended.withLock { $0 = true }
                return
            }
            receive()
        }
    }
}

/// 127.0.0.1 のポートへ WebSocket で繋ぐ相手 (ブラウザの代わり)。届いた text を 1 通ずつ溜める。
nonisolated final class BrowserSocket: LoopbackPeer, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.websocket")
    private let connection: NWConnection
    private let texts = Mutex<[String]>([])
    private let link = Mutex(PeerState.connecting)
    private let ended = Mutex(false)

    init(port: Int, path: String = "/") {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(
            to: .url(URL(string: "ws://127.0.0.1:\(port)\(path)")!), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            self?.link.withLock { $0 = state.peerState(after: $0) }
        }
        connection.start(queue: queue)
        receive()
    }

    /// 繋ぎの状態 (``LoopbackPeer``)。
    var state: PeerState { link.withLock { $0 } }
    /// 届いた text。届いた順。
    var received: [String] { texts.withLock { $0 } }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    /// 1 通の text として送る。
    func send(_ text: String) {
        send(Data(text.utf8), opcode: .text)
    }

    /// 1 通の binary として送る。
    func sendBinary(_ bytes: [UInt8]) {
        send(Data(bytes), opcode: .binary)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func send(_ content: Data, opcode: NWProtocolWebSocket.Opcode) {
        let context = NWConnection.ContentContext(
            identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: content, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                ended.withLock { $0 = true }
                return
            }
            // 空の 1 通は content が nil で届く。落とさずに空の文字列として積む
            if metadata.opcode == .text {
                texts.withLock { $0.append(String(decoding: content ?? Data(), as: UTF8.self)) }
            }
            receive()
        }
    }
}
