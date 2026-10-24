// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Synchronization

/// 「初回だけ知らせる」注意の控え。
///
/// ## なぜ 1 つの型に畳むのか
///
/// 毎フレーム起きうる事情は繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。その
/// 規律を旗で守ると、注意 1 種類につき `Bool` の宣言・`guard`・代入の 3 か所が要り、
/// `Drawing` だけで 31 個並んでいた ([#734])。**控えを 1 つ持って種類を鍵で数えれば、
/// 注意を足すときに増えるのは鍵 1 つと呼び出し 1 行だけになる。**
///
/// ## 鍵は呼ぶ側が enum で決める
///
/// 綴りと網羅性をコンパイラに見せるためである。文字列を鍵にすると、離れた 2 か所で
/// 同じ綴りを書いた時点で**片方が永久に黙る**うえ、黙ったことは絵にもログにも出ない。
/// enum なら、鍵を共有していることは定義を見れば分かる。
///
/// [#734]: https://github.com/mokume-metal/mokume/issues/734
///
/// **隔離を持たない。** 持っているのは自分の控えだけで、``Diagnostics`` と同じく
/// 共有する状態が無いため、置かれた側の隔離に合わせる理由が無い。
nonisolated struct WarningLog<Key: Hashable> {
    /// 言った注意と、そのとき出した文面。
    ///
    /// 集合ではなく対応表で持つ。**出した文面をそのまま控える**ためで、こうすると
    /// 「1 度しか言わない」も「何と言ったか」も、標準エラーを覗かずに確かめられる。
    /// 控えるのは高々鍵の種類の数で、フレームでは増えない (鍵が値を持つ注意は、呼ぶ側が
    /// 言う数に上限を置く — ``count(where:)``)。
    private var said: [Key: String] = [:]

    /// 言った文面を控える。``SharedWarningLog`` が、**文面の組み立てと標準エラーへの書き込みを
    /// 錠の外で済ませた後**に載せるための入口。``warnOnce(_:_:)`` を通らずに載せるので、
    /// 呼ぶ側が「同じ鍵を 2 度載せない」ことを守る。
    mutating func record(_ key: Key, _ text: String) { said[key] = text }

    /// まだ言っていなければ、その注意を 1 度だけ言う。2 度目からは何もしない。
    ///
    /// 文面は `@autoclosure` で受ける。**言わない回は組み立てない** — 呼ばれる場所は
    /// 頂点 1 つごとの経路まで含むので、黙る回に文字列を確保すると、畳んだぶんだけ
    /// 遅くなる。旗で守っていたときと同じく、確保が起きるのは最初の 1 回だけである。
    mutating func warnOnce(_ key: Key, _ message: @autoclosure () -> String) {
        guard said[key] == nil else { return }
        let text = message()
        said[key] = text
        Diagnostics.warn(text)
    }

    /// その注意を既に言ったか。**検査が読む。**
    func hasWarned(_ key: Key) -> Bool { said[key] != nil }

    /// その注意で出した文面。まだ言っていなければ `nil`。**検査が文言を読む。**
    func message(for key: Key) -> String? { said[key] }

    /// 言った注意のうち、条件に合う鍵の数。
    ///
    /// 鍵が値を持つ注意 (行き先ごとに 1 度言う書き損じ・``FrameRecorder``) の、言った数に
    /// 上限を置くためにある。数を別に持つと、控えと数の 2 つを揃えて空に戻す必要が出る。
    func count(where isIncluded: (Key) -> Bool) -> Int { said.keys.count(where: isIncluded) }
}

nonisolated extension WarningLog: Sendable where Key: Sendable {}

/// 複数のスレッドから言える「初回だけ知らせる」控え ([#2389])。
///
/// 値だけを扱う数と色の関数 (``map(_:_:_:_:_:)`` や ``color(_:_:_:_:)``) は、持ち主の面が無いので
/// 控えをプロセスで 1 つ持つ。これらを `nonisolated` にして、`concurrentPerform` や TaskGroup から
/// 並べて呼べるようにすると、**同じ注意を同時に言いうる**。どのスレッドから何本呼んでも、
/// 注意は 1 度だけ出る。
///
/// 面が持つ控え (``Canvas/warnings`` など) は main actor の中だけで触るので、``WarningLog`` のまま
/// 持つ。ここへ寄せるのは、持ち主が無く、隔離の外から呼ばれうる口だけである。
///
/// ## 錠は「初めて言う 1 回」にしか取らない
///
/// 範囲の外を締める入力が毎画素来る並列のループでは、言い終えた後の回が大多数になる。その回ごとに
/// プロセスで 1 つの錠を取ると、全スレッドが 1 本の錠に並ぶ ([#2389] の反証)。そこで、
///
/// 1. **言う権利を取った鍵は、錠を取らずに抜ける。** その鍵を、追記するだけの連結リストに公開してあり、
///    先にそれを錠なしで辿る。載っていれば、言うのは別のスレッドが済ませたか、いま言っている最中である。
///    **見えるのは「公開された番地を読めたなら、節の中身が読める」ところまでで** (読み出しは取得順序、
///    載せる側は公開順序)、載せた直後の鍵を別のスレッドが必ず見られるとは限らない。古い「無い」を
///    読んだ回は、次の 2 の錠の中の確かめが受け止めるので、注意が 2 度出ることは無い
/// 2. **初めての回だけ錠を取る。** 錠の中は「この鍵は初めてか」の確かめと印だけで、**文面の組み立てと
///    標準エラーへの書き込みは錠の外**で行う。文面の中から同じ控えの口を呼んでも錠の再入にならず、
///    標準エラーが詰まっても、言わない回を巻き込んで止めない
///
/// 言う権利を取るのは 1 スレッドだけなので、文面の組み立ても 1 度だけである。
///
/// ## 写しが答えるのは、言い終えた鍵だけ
///
/// 権利を取ってから言い終えるまでには隙間がある。その間の鍵は、``snapshot`` に**載らない** —
/// 写しで `hasWarned` が真なら、文面は標準エラーと溜め場へ届いた後で、`message(for:)` は
/// 空でない文面を返す。権利だけを取った鍵は別に持つ (錠の中の `pending`)。
///
/// ## 鍵は、値を持たない有限の enum にする
///
/// 公開した節は返さない (読む側が錠なしで辿るため、返す時期を決められない)。``WarningLog`` の
/// 「値を持つ鍵は、呼ぶ側が言う数に上限を置く」口 (行き先ごとに 1 度言う `URL` の鍵など) は、
/// **ここへ置かない**。`==` が反射的でない鍵も同じで、呼ぶたびに節が増える。上限を越えて公開しようと
/// すると、debug では `assert` で止まる (``maximumKeys``)。
///
/// ## 溜め場を差し替えて数える検査
///
/// 文面が届く溜め場 (``Diagnostics/digest``) は、**権利を取ったスレッドのタスクローカル値**で決まる。
/// 溜め場を差し替えて並列の呼び出しを数える検査は、`withTaskGroup` の子のタスクで言わせる
/// (子は引き継ぐ)。`DispatchQueue.concurrentPerform` の作業スレッドは引き継がないので、どの溜め場に
/// 入るかがスレッドの勝ち負けで変わる。
///
/// [#2389]: https://github.com/mokume-metal/mokume/issues/2389
nonisolated final class SharedWarningLog<Key: Hashable & Sendable>: Sendable {
    /// 言った鍵の連結リストの 1 つ。**追記だけで、載せた鍵は消えない。**
    ///
    /// **参照を数える物にしない** (生のポインタと番地で持つ)。読む側が節を `retain` / `release` すると、
    /// 全スレッドが同じ節の参照カウントを書き換えて、錠より遅くなる (#2389 の実測)。節は載せたら
    /// 書き換えず (末尾のときに `next` へ 1 度書くだけ)、読むだけなら共有の読み出しなので、
    /// スレッドが増えても詰まらない。
    private struct Node: ~Copyable {
        let key: Key
        /// 次の節の番地。0 は末尾。
        let next = Atomic<UInt>(0)
    }

    /// 言い終えた控えと、権利だけを取って言っている最中の鍵。**錠の中でだけ触る。**
    private struct State: Sendable {
        var said = WarningLog<Key>()
        var pending = Set<Key>()
        var published = 0
    }

    /// 公開できる鍵の数の上限 (debug で `assert` する)。数えるのは、値を持たない有限の enum の事情の種類。
    static var maximumKeys: Int { 256 }

    private let state = Mutex(State())
    /// 先頭の節の番地。0 は何も載っていない。
    private let first = Atomic<UInt>(0)

    deinit {
        // 読む側はもう居ない。節を先頭から辿って返す
        var address = first.load(ordering: .acquiring)
        while address != 0, let node = UnsafeMutablePointer<Node>(bitPattern: address) {
            address = node.pointee.next.load(ordering: .acquiring)
            node.deinitialize(count: 1)
            node.deallocate()
        }
    }

    /// その鍵が公開されているか。**錠を取らない。**
    private func isPublished(_ key: Key) -> Bool {
        var address = first.load(ordering: .acquiring)
        while address != 0, let node = UnsafeMutablePointer<Node>(bitPattern: address) {
            if node.pointee.key == key { return true }
            address = node.pointee.next.load(ordering: .acquiring)
        }
        return false
    }

    /// 鍵を連結リストの末尾に公開する。**錠の中でだけ呼ぶ** (書き手は常に 1 人)。
    private func publish(_ key: Key) {
        let node = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        node.initialize(to: Node(key: key))
        let address = UInt(bitPattern: node)
        var slot = first.load(ordering: .acquiring)
        guard slot != 0 else { return first.store(address, ordering: .releasing) }
        while true {
            let current = UnsafeMutablePointer<Node>(bitPattern: slot)!
            let next = current.pointee.next.load(ordering: .acquiring)
            if next == 0 { return current.pointee.next.store(address, ordering: .releasing) }
            slot = next
        }
    }

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    func warnOnce(_ key: Key, _ message: @autoclosure () -> String) {
        guard !isPublished(key) else { return }
        let isFirst = state.withLock { state in
            guard !state.said.hasWarned(key), state.pending.insert(key).inserted else { return false }
            assert(
                state.published < Self.maximumKeys,
                "SharedWarningLog の鍵が \(Self.maximumKeys) を超えた。値を持つ鍵は WarningLog に置き、呼ぶ側が上限を置く")
            state.published += 1
            publish(key)
            return true
        }
        guard isFirst else { return }
        // 先に届けてから控える。写しに載った鍵は、文面が届いた後である
        let text = message()
        Diagnostics.warn(text)
        state.withLock { state in
            state.pending.remove(key)
            state.said.record(key, text)
        }
    }

    /// いま言い終えている注意の写し。**検査が読む。** 言っている最中の鍵は載らない。
    var snapshot: WarningLog<Key> { state.withLock { $0.said } }
}
