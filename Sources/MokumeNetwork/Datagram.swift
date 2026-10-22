// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeDiagnostics
import Network

// UDP の受け・送り。**中身のバイト列をどう読むかは持たない** — 上の層 (OSC の ``OSCCodec``・
// 文字列の ``TextDecoding``) が決める。ポートを開く部分は TCP・WebSocket と ``PortListener`` を
// 共有する (待ち行列の扱いと ADR-0042 決定 7 の条件も、そちらの冒頭に書いた)。

/// UDP の 1 つの datagram の大きさ。**受けも送りも、``sizeLimit`` バイト未満 (9215 バイトまで)
/// だけを扱う** (#2325)。
///
/// macOS の Network.framework の受け口は、9216 バイトを超える datagram を先頭 9216 バイトに切り、
/// 切れたことを知らせずに渡す (`isComplete` も真のまま。受ける長さを指定しても同じ。macOS 27.0.1 で
/// 実測)。切れた先頭を渡すと、UDP では黙って別の文字列に、OSC では束の頭のメッセージだけになる。
/// 切れたものとちょうど 9216 バイトのものは見分けられないので、**9216 バイト以上は切れた疑いがある
/// として丸ごと捨てて数える** — ちょうど 9216 バイトの正しい datagram も捨てる代償は、メンテナが
/// 受け入れた (#2325 の決定。全長を受けるには、受けを Network.framework から外すことになる)。
///
/// 送りも同じ数にそろえる。mokume が送ったものを mokume の受け口が捨てないためで、
/// Network.framework の送り口が送れる大きさ (9216 バイトまで。超えると `Message too long`) にも収まる。
nonisolated enum Datagram {
    /// 大きさの上限 (バイト)。これ**以上**の datagram は、受けても捨てて数え、送らない。
    static let sizeLimit = 9216

    /// 扱える最大の大きさ (バイト)。診断の文面に出す。
    static var largest: Int { sizeLimit - 1 }

    /// `count` バイトの datagram を扱えるか。
    static func fits(_ count: Int) -> Bool { count < sizeLimit }
}

/// UDP のポートを 1 つ開いて、届いた datagram を 1 つずつ渡す。
///
/// **ポートが使えなくても投げない。** 開く・使用中を見分ける・開き直すのは ``PortListener`` の
/// とおりで、移り変わりは ``Event`` で知らせる。
nonisolated final class DatagramListener: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``ledger``・``stopped``) は ``queue`` の上でだけ触る。
    // Network.framework の手続きもすべて ``queue`` で走らせる (ポートを開く ``opener`` も同じ
    // 待ち行列を使う)。

    /// 受け口の移り変わり。
    typealias Event = PortListener.Event

    /// 頼んだポート。0 なら OS が空いている番号を選ぶ。
    var port: Int { opener.port }
    /// 受けるアドレス。`nil` ならすべての口 (別の機械からも届く)。
    var host: String? { opener.host }
    /// 失敗したとき、何秒後に開き直すか。
    var retryAfter: TimeInterval { opener.retryAfter }
    /// 何秒黙っていた送り元を、閉じてよいとするか。
    let idleAfter: TimeInterval

    /// 持つ送り元の数の目安。これに達したら、新しい送り元を受ける前に黙っている送り元を閉じる。
    ///
    /// UDP の受け口は、送り元 (アドレスとポート) ごとに `NWConnection` を 1 つ作る。送るたびに
    /// 新しいポートから送る相手 (使い捨てのソケットで送るスクリプトなど) が居ると、閉じない
    /// 限り際限なく増える。閉じた送り元からまた届けば、新しく作り直される。
    ///
    /// **閉じるのは、読んだ後に ``idleAfter`` 秒以上黙っている送り元だけである。** 届いたばかりの
    /// 送り元を閉じると、まだ読んでいない datagram ごと捨ててしまう (多くの送り元から一度に
    /// 届いたとき、先に着いた送り元を閉じて落とすことを検査で確かめた)。まだ 1 度も読んでいない
    /// 送り元は、受け入れから何秒経っても閉じない (``SenderLedger``・#2225)。だから一度に多く
    /// 届いた間は数がこれを超えてよく、黙った後の次の受け入れで戻る。
    static let connectionLimit = 64

    /// 「空で流れが閉じた」と知らせた送り元を覚えておく数の上限。覚えておくのは、同じ送り元に 2 度
    /// 言わないためで、空を送る送り元が際限なく変わっても状態が増えない。**超えたら、先に覚えた送り元から
    /// 忘れる。** 忘れた送り元がまた空で流れを閉じたら、もう 1 度言う (#2363)。
    static let emptyClosedLimit = 256

    /// 黙っている送り元を閉じてよいとするまでの秒数 (既定)。
    static let defaultIdleAfter: TimeInterval = 5

    /// 送り元の黙りを測る既定の時計 (秒)。眠っている間は進まない `systemUptime`。受け口と
    /// OSC の出どころの既定はこれ 1 つで、検査は本番と同じこの時計でも閉じることを見る。
    static let systemClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let queue = DispatchQueue(label: "org.mokume.network.listener")
    private let now: @Sendable () -> TimeInterval
    private let received: @Sendable ([UInt8], UInt64) -> Void
    private let closedByEmpty: @Sendable (String) -> Void
    /// 空で流れが閉じたと知らせた送り元 (``closedByEmpty``)。同じ送り元には 2 度言わない。
    private var toldEmptyClosed = EmptyClosedSenders(limit: DatagramListener.emptyClosedLimit)
    /// 受け口。閉じたときの知らせに自分を渡すので、他をすべて決めた後に作る。
    private var opener: PortListener!
    /// 送り元と、最後に読んだ時刻 (``now`` の目盛り)。
    private var ledger: SenderLedger<NWConnection>
    private var stopped = false

    /// - Parameters:
    ///   - port: 開くポート。0 なら OS が選ぶ。
    ///   - host: 受けるアドレス。`nil` ならすべての口。
    ///   - retryAfter: 失敗したとき、何秒後に開き直すか。
    ///   - idleAfter: 何秒黙っていた送り元を、閉じてよいとするか。
    ///   - now: 送り元の黙りを測る時計 (秒)。既定は ``systemClock``。検査は手で進める時計を
    ///     渡し、受け入れの速さに依らずに黙りを決める (#2225)。``queue`` の上で呼ばれる。
    ///   - received: 届いた datagram と、届いた瞬間の host time。``queue`` の上で呼ばれる。
    ///   - closedByEmpty: 終わりを名乗った空の datagram を渡してこちらで流れを閉じたとき、その送り元
    ///     (`127.0.0.1:51234`) で呼ぶ。**同じ送り元には 1 度だけ** (覚える数は ``emptyClosedLimit``)。
    ///     ``queue`` の上で呼ばれる。
    ///   - changed: 移り変わり。``queue`` の上で呼ばれる。
    init(
        port: Int, host: String?, retryAfter: TimeInterval,
        idleAfter: TimeInterval = defaultIdleAfter,
        now: @escaping @Sendable () -> TimeInterval = systemClock,
        received: @escaping @Sendable ([UInt8], UInt64) -> Void,
        closedByEmpty: @escaping @Sendable (String) -> Void = { _ in },
        changed: @escaping @Sendable (Event) -> Void
    ) {
        self.idleAfter = idleAfter
        self.now = now
        self.received = received
        self.closedByEmpty = closedByEmpty
        ledger = SenderLedger(limit: Self.connectionLimit, idleAfter: idleAfter)
        opener = PortListener(
            port: port, host: host, retryAfter: retryAfter, queue: queue,
            parameters: { .udp }, changed: changed,
            closed: { [weak self] in self?.listenerClosed() })
    }

    /// 開き始める。待たずに返る。
    func start() {
        opener.start { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            accept(connection)
        }
    }

    /// いま持っている送り元の数 (検査が上限を確かめるため)。
    var connectionCount: Int { queue.sync { ledger.count } }

    /// 送り元の出入りの数 (検査が「黙っていない送り元は閉じない」を確かめるため)。
    var tally: SenderTally { queue.sync { ledger.tally } }

    /// 閉じる。**閉じ終わるまで待つ** — 返った後に届いたものは渡さない。
    func stop() {
        queue.sync { [self] in
            stopped = true
            opener.cancel()
            for connection in ledger.removeAll() { connection.cancel() }
        }
    }

    /// 待ち行列の上で手続きを走らせる。検査が ``listenerClosed()`` を、受け口を本当に
    /// 失敗させずに呼ぶための口。
    func onQueue<Result>(_ body: () -> Result) -> Result {
        queue.sync(execute: body)
    }

    // MARK: - 待ち行列の上

    /// 受け口 (`NWListener`) が失敗して閉じた。送り元をすべて台帳から外して閉じる。
    ///
    /// 開き直した受け口は、送り元ごとに繋ぎを作り直す。閉じた受け口の繋ぎを台帳に残すと、
    /// その待っていた受けが空の datagram と同じ形 (`content == nil`・`error == nil`) で
    /// 返ったときに、届いていない空のメッセージとして渡してしまう。外した繋ぎは
    /// ``SenderTally`` に数えない。``PortListener`` が ``queue`` の上で呼ぶ。
    func listenerClosed() {
        dispatchPrecondition(condition: .onQueue(queue))
        for connection in ledger.removeAll() { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        for idle in ledger.admit(connection, at: now()) { idle.cancel() }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                ledger.ended(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// 送り元の繋ぎから、datagram を 1 つずつ読み続ける。扱いは ``completion(content:isFinal:failed:held:)``。
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, _, error in
            let hostTime = mach_absolute_time()
            guard let self, let connection, !stopped else { return }
            let completion = Self.completion(
                content: content, isFinal: context?.isFinal == true, failed: error != nil,
                held: ledger.holds(connection))
            switch completion {
            case .ended:
                connection.cancel()
            case .abandoned:
                break
            case .datagram(let bytes):
                ledger.heard(connection, at: now())
                received(bytes, hostTime)
                receive(on: connection)
            case .last(let bytes):
                ledger.heard(connection, at: now())
                received(bytes, hostTime)
                connection.cancel()
            }
            // 空の直後に同じ送り元から届いたものは、Network.framework が捨てうる (#2363)。
            // 何が落ちたかは見えないので、流れが閉じたことを送り元ごとに 1 度だけ言う
            if completion.closesFlowOnEmpty {
                let sender = Self.describe(connection.endpoint)
                if toldEmptyClosed.insert(sender) { closedByEmpty(sender) }
            }
        }
    }

    /// 送り元の名乗り (`127.0.0.1:51234`・IPv6 は `[::1]:51234`)。診断に出す。
    static func describe(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "\(endpoint)" }
        // 範囲指定 (`fe80::1%en0`) の `%` 以降は、診断の読み手に要らない
        let address = "\(host)".split(separator: "%", maxSplits: 1).first.map(String.init) ?? "\(host)"
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// 受けの完了 1 つの扱い。
    enum Completion: Equatable {
        /// datagram として渡し、受けを続ける。
        case datagram([UInt8])
        /// datagram として渡し、繋ぎを閉じる。
        case last([UInt8])
        /// 繋ぎが終わった。閉じる。
        case ended
        /// こちらが閉じた繋ぎの、待っていた受けの返り。何も渡さない。
        case abandoned

        /// 空の datagram を渡して流れを閉じる扱いか。**この扱いだけが、空の直後に届いたものが落ちたかも
        /// しれないことを名乗る** (#2363)。終わりを名乗らない空 (流れが続く)・こちらが閉じた繋ぎ
        /// (黙りで閉じた・受け口が失敗した)・空を含まない流れの終わりでは、何も落ちた疑いが無い。
        var closesFlowOnEmpty: Bool {
            if case .last = self { return true }
            return false
        }
    }

    /// 受けの完了が渡したもの (`content`・文脈の `isFinal`・失敗したか) と、その繋ぎをまだ台帳に
    /// 持っているか (`held`) から、扱いを決める。
    ///
    /// **空の datagram (0 バイト) も 1 つの datagram として渡す。** Network.framework は空の
    /// datagram を `content == nil`・`error == nil` で渡す。送り元の流れができて受けを待っている
    /// ところへ届いた空には、流れの終わり (`isFinal`) も名乗り、次の受けを `ENODATA` で返して
    /// 流れを閉じる (macOS 27.0.1 で実測。流れの最初の datagram と一緒に届いた空は、たいてい
    /// 終わりを名乗らない)。空を終わりと読むと、空そのものを黙って捨てる (#2324)。だから終わりを
    /// 名乗った空も渡し、**渡してからこちらで閉じる** — 閉じた流れが空を返し続ける OS でも、
    /// 次の受けの `error` を待たずに止まる (実測は 27.0.1 だけ)。中身のある datagram は、
    /// `isFinal` に依らず渡して続ける。
    ///
    /// 流れが閉じた後に届いたものは、新しい送り元として受け直す。**閉じる前にその流れへ積まれて
    /// いたもの (空の直後 1 ミリ秒ほどの間に同じ送り元から届いたもの) は Network.framework が
    /// 捨て、ここからは見えない** (#2324・#2363。受けを Network.framework から外さない限り
    /// 避けられない)。
    ///
    /// 待っていた受けは、こちらが繋ぎを閉じたとき (黙った送り元・受け口の失敗) にも
    /// `content == nil`・`error == nil` で返る。届いていない空を渡さないよう、台帳から外した
    /// 繋ぎの**中身の無い**受けは何も渡さない。中身のある受けは、台帳から外した後に返っても、
    /// 届いた datagram なので渡す。
    static func completion(content: Data?, isFinal: Bool, failed: Bool, held: Bool) -> Completion {
        if failed { return .ended }
        if let content { return .datagram([UInt8](content)) }
        guard held else { return .abandoned }
        return isFinal ? .last([]) : .datagram([])
    }
}

/// 「空で流れが閉じた」と知らせた送り元の覚え (#2363)。同じ送り元に 2 度言わず、**覚える数に上限を持つ**。
/// 上限を超えたら、先に覚えた送り元から忘れる (忘れた送り元がまた閉じたら、もう 1 度言う)。
nonisolated struct EmptyClosedSenders {
    let limit: Int
    private var order: [String] = []
    private var known: Set<String> = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// 覚えている数。
    var count: Int { order.count }

    /// `sender` を覚える。まだ知らなければ真 (言う)、覚えていれば偽 (もう言った)。
    mutating func insert(_ sender: String) -> Bool {
        guard known.insert(sender).inserted else { return false }
        order.append(sender)
        if order.count > limit { known.remove(order.removeFirst()) }
        return true
    }
}

/// 送り元の出入りの数。
nonisolated struct SenderTally: Sendable, Equatable {
    /// 受け入れた送り元の数。
    var accepted = 0
    /// 黙っていたとして閉じた数。
    var closedIdle = 0
    /// 繋ぎが台帳に居るまま終わって外れた数。失敗・取り消しのほか、終わりを名乗った空の
    /// datagram を渡してこちらが閉じたもの (#2324) も数える。黙りで閉じたもの・受け口ごと
    /// 閉じたもの・受け口が失敗して外したものは、先に台帳から外すので数えない。
    var ended = 0
}

/// 受け口が持つ送り元の台帳。送り元ごとに最後に読んだ時刻を持ち、数が目安に達したときに
/// 閉じてよい送り元を決める。
///
/// 繋ぎの型に依らない値で、時刻は呼ぶ側が渡す。検査は繋ぎも時計も無しに、閉じる判断を回せる。
nonisolated struct SenderLedger<Sender: AnyObject> {
    /// 数の目安 (``DatagramListener/connectionLimit``)。
    let limit: Int
    /// 何秒黙っていた送り元を、閉じてよいとするか。
    let idleAfter: TimeInterval
    /// 送り元と、最後に読んだ時刻。**まだ 1 度も読んでいなければ `nil` で、黙りを測らない** —
    /// 受け入れたばかりの繋ぎには読む前の datagram が必ずある。受け入れた時刻から測ると、
    /// 待ち行列が混んで最初に読むまでに ``idleAfter`` 秒を越えたとき、それごと捨ててしまう (#2225)。
    private var entries: [(sender: Sender, heard: TimeInterval?)] = []
    private(set) var tally = SenderTally()

    init(limit: Int, idleAfter: TimeInterval) {
        self.limit = limit
        self.idleAfter = idleAfter
    }

    /// いま持っている送り元の数。
    var count: Int { entries.count }

    /// 新しい送り元を受け入れる。数が目安に達していれば、先に黙っている送り元を台帳から外して
    /// 返す (閉じるのは呼ぶ側)。
    mutating func admit(_ sender: Sender, at time: TimeInterval) -> [Sender] {
        var idle: [Sender] = []
        if entries.count >= limit {
            entries.removeAll { entry in
                guard let heard = entry.heard, time - heard >= idleAfter else { return false }
                idle.append(entry.sender)
                return true
            }
        }
        entries.append((sender, nil))
        tally.accepted += 1
        tally.closedIdle += idle.count
        return idle
    }

    /// 送り元を持っているか。黙りで閉じた・失敗や取り消しで外れた・受け口ごと閉じた後は偽。
    func holds(_ sender: Sender) -> Bool {
        entries.contains { $0.sender === sender }
    }

    /// 送り元から読んだ。
    mutating func heard(_ sender: Sender, at time: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.sender === sender }) else { return }
        entries[index].heard = time
    }

    /// 失敗・取り消しで終わった送り元を外す。台帳に居なければ (黙りで閉じた後・受け口ごと
    /// 閉じた後なら) 何もしない。
    mutating func ended(_ sender: Sender) {
        guard let index = entries.firstIndex(where: { $0.sender === sender }) else { return }
        entries.remove(at: index)
        tally.ended += 1
    }

    /// すべて外して返す (受け口ごと閉じるとき)。
    mutating func removeAll() -> [Sender] {
        defer { entries.removeAll() }
        return entries.map(\.sender)
    }
}

/// UDP で 1 つの宛先へ送る。
protocol DatagramSending: AnyObject, Sendable {
    /// 送る。待たずに返る。
    func send(_ bytes: [UInt8])
    /// 閉じる。
    func stop()
}

/// UDP で 1 つの宛先 (ホストとポート) へ送る。
///
/// **送れなくても投げない。** 送れないときは理由を添えて 1 度だけ知らせ、送れたら、また知らせられる
/// ように戻す。知らせるのは 2 つの形である。
///
/// - **繋ぎが失敗した** (`failed`。宛先で誰も受けていない `connection refused` など) — 繋ぎを捨て、
///   次に送るときに繋ぎ直す。**送れたと読めるのは、繋ぎが ``confirmAfter`` 秒以上、拒まれずに
///   送れ続けたとき**である (下の「UDP の送れた」)
/// - **繋ぎが待っている** (`waiting`。`Network is down` など) — 繋ぎは Network.framework が自分で
///   待ち続けるので捨てない。待っている間は送ったものの完了が 1 度も返らず、知らせなければ**黙って
///   消える**。ネットワークが生きているのに待つなら、このアプリにローカルネットワークの許可が
///   無いことがある (束ねた `.app` で、ダイアログが出ないまま塞がれたときに実測した — #1962)。
///   `Network is down` は Wi-Fi が落ちているときにも出るので、許可の拒否と断定はしない
///
/// ## UDP の送れた
///
/// UDP の送信の完了は「手元のソケットから出た」ことしか言わない。宛先で誰も受けていない拒否は
/// **次の送信**の失敗として返り、繋ぎはそのまま使える (macOS 27.0.1 で、受け手の居ないポートへ
/// 繋ぎを捨てずに送ると、完了が成功・拒否を交互に返すのを実測した)。完了が誤り無しで返ったことを
/// 「送れた」と読むと、誰にも届いていないのに送るたびに戻って、1 度だけのはずの診断が出直す
/// (#2326)。
///
/// だから**拒否で名乗った後は、同じ繋ぎで最初に誤り無く終わった送信の完了から ``confirmAfter`` 秒以上
/// 後に出した送信も誤り無く終わって初めて**、送れたと読む。拒否は送信から宛先の往復の間に届くので、
/// それより長く待ってから出した送信が拒まれなければ、最初の送信は届いていた。**測るのは 2 つ目を
/// 出した時刻で、完了が返った時刻ではない** — 待ち行列が遅れて 2 つ目が拒否の到着より前に出ていても、
/// 完了の時刻だけを見ると間を満たしてしまう。受け手が居ないままなら、繋ぎは 2 つ目の送信の前に
/// 拒否で捨てられるので、戻らない。
///
/// **捨てた繋ぎ (いまの繋ぎでないもの) に返った完了は、いまの繋ぎの話ではないので無視する。** 繋ぎを
/// 捨てると、その繋ぎに積まれていた送信の完了が `ECANCELED` などの誤りで返る。それを送れない理由として
/// 名乗らず、いまの繋ぎの数え方も崩さない。
///
/// 送れないことは受け口の状態 (``OSCPort/state``) には出さない。
nonisolated final class DatagramSender: DatagramSending, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``connection``・``warned``) は ``queue`` の上でだけ触る。

    let host: String
    let port: Int
    /// 拒否で名乗った後、送れたと読むまでに、同じ繋ぎで空ける間 (秒) の既定。拒否は宛先との往復の間に
    /// 届くので、それより長ければよい。長すぎると、受け手が戻ってから次に落ちたときの名乗りが遅れる。
    static let defaultConfirmAfter: TimeInterval = 0.5

    /// 拒否で名乗った後、送れたと読むまでに、同じ繋ぎで空ける間 (秒)。
    let confirmAfter: TimeInterval
    private let queue = DispatchQueue(label: "org.mokume.network.sender")
    private let now: @Sendable () -> TimeInterval
    private let warn: @Sendable (String) -> Void
    private var connection: NWConnection?
    private var warned = false
    /// いま名乗っているのが、宛先の失敗 (拒否など) か。偽なら (待っている) 送れた 1 度で戻る。名乗った
    /// 後に宛先の失敗が返れば、理由が待ちでも真にする (次の誤り無しの完了で戻して言い直さない)。
    private var refused = false
    /// いまの繋ぎで、最初に誤り無く終わった送信の完了の時刻。繋ぎを捨てる・失敗が返るたびに消える。
    private var unrefutedSince: TimeInterval?

    /// - Parameters:
    ///   - confirmAfter: 拒否で名乗った後、送れたと読むまでに、同じ繋ぎで空ける間 (秒)。
    ///   - now: その間を測る時計 (秒)。検査は手で進める時計を渡す。
    init(
        host: String, port: Int, confirmAfter: TimeInterval = defaultConfirmAfter,
        now: @escaping @Sendable () -> TimeInterval = DatagramListener.systemClock,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.host = host
        self.port = port
        self.confirmAfter = confirmAfter
        self.now = now
        self.warn = warn
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            let connection = connection ?? open()
            let issued = now()
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { [weak self, weak connection] error in
                    self?.finished(sending: error, on: connection, issuedAt: issued)
                })
        }
    }

    func stop() {
        queue.sync { [self] in
            connection?.cancel()
            connection = nil
            unrefutedSince = nil
        }
    }

    /// 待ち行列の上で手続きを走らせる。検査が状態の読み替え (``changed(to:on:)``・
    /// ``finished(sending:on:)``) を、本物の繋ぎを作らずに呼ぶための口。
    func onQueue<Result>(_ body: () -> Result) -> Result {
        queue.sync(execute: body)
    }

    // MARK: - 待ち行列の上

    private func open() -> NWConnection {
        let opened = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any,
            using: .udp)
        opened.stateUpdateHandler = { [weak self, weak opened] state in
            self?.changed(to: state, on: opened)
        }
        opened.start(queue: queue)
        attach(opened)
        return opened
    }

    /// 繋ぎをいまの繋ぎにする。検査は、始めていない繋ぎをここへ据えて、いまの繋ぎの完了と
    /// 捨てた繋ぎの完了を作り分ける。
    func attach(_ opened: NWConnection) {
        connection = opened
        unrefutedSince = nil
    }

    /// 繋ぎの移り変わりを読む。送れない形なら 1 度だけ知らせる。
    func changed(to state: NWConnection.State, on opened: NWConnection?) {
        switch state {
        case .waiting(let error):
            // 繋ぎは Network.framework が自分で待ち続ける。捨てずに、送れないことだけを言う
            tell(error, cause: .waiting)
        case .failed(let error):
            if let opened { drop(opened) }
            tell(error, cause: .destination)
        default:
            break
        }
    }

    /// 1 つ送り終えた。送れたら、また知らせられるように戻す。
    ///
    /// 「送れた」が何かは、名乗った理由で違う。待っているときは、誤り無く終わった 1 度で戻す。
    /// **宛先の失敗 (拒否など) は、完了が誤り無しで返っても戻さない** — 拒否は次の送信の失敗として
    /// 返るので、同じ繋ぎで最初に誤り無く終わった完了から ``confirmAfter`` 秒以上後に出した送信も誤り
    /// 無く終わって初めて戻す (型の説明の「UDP の送れた」)。
    ///
    /// - Parameter issuedAt: この送信を出した時刻。`nil` なら、いま。
    func finished(sending error: NWError?, on sent: NWConnection?, issuedAt: TimeInterval? = nil) {
        guard let error else {
            guard warned else {
                if isCurrent(sent) { unrefutedSince = unrefutedSince ?? now() }
                return
            }
            guard refused else {
                warned = false
                return
            }
            // 捨てた繋ぎの完了は、いまの繋ぎの数え方に入れない
            guard isCurrent(sent) else { return }
            let completed = now()
            let since = unrefutedSince ?? completed
            unrefutedSince = since
            if (issuedAt ?? completed) - since >= confirmAfter { warned = false }
            return
        }
        // 捨てた繋ぎに積まれていた送信の完了は、どんな誤りでも、いまの繋ぎの話ではない
        guard isCurrent(sent) else { return }
        unrefutedSince = nil
        if let sent { drop(sent) }
        tell(error, cause: .destination)
    }

    /// `sent` がいまの繋ぎか。**弱参照が消えた (`nil`) ものはいまの繋ぎではない** — いまの繋ぎは
    /// こちらが持っているので消えない。
    private func isCurrent(_ sent: NWConnection?) -> Bool {
        guard let sent else { return false }
        return connection === sent
    }

    /// 繋ぎを捨てる。次に送るときに作り直す。
    private func drop(_ failed: NWConnection) {
        failed.cancel()
        if connection === failed {
            connection = nil
            unrefutedSince = nil
        }
    }

    /// 送れない理由。名乗る言葉と、戻す条件が違う。
    private enum Cause {
        /// 繋ぎが待っている (許可が無い・ネットワークが落ちている)。
        case waiting
        /// 繋ぎや送信が失敗した (宛先で誰も受けていないなど)。
        case destination
    }

    private func tell(_ error: NWError, cause: Cause) {
        // 待っていると名乗った後に宛先の失敗が返ったら、以後は拒否として戻す
        if cause == .destination { refused = true }
        guard !warned else { return }
        warned = true
        refused = cause == .destination
        let head = "Could not send to \(host):\(port) (\(Self.describe(error)))."
        switch cause {
        case .waiting:
            warn(
                head + " If the network is up, this app may not be allowed to reach the local "
                    + "network: check System Settings > Privacy & Security > Local Network. It keeps "
                    + "waiting for the connection")
        case .destination:
            warn(head + " Check that something is listening there; the next message tries again")
        }
    }

    /// 失敗の名乗り。POSIX の失敗は OS の文面 (`Network is down` など) にする。作り方は本体と 1 つ
    /// (``Diagnostics/posixReason(_:)``・#2839)。
    static func describe(_ error: NWError) -> String {
        guard case .posix(let code) = error else { return error.debugDescription }
        return Diagnostics.posixReason(code.rawValue)
    }
}
