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

    /// 言う権利を取る。まだ言っていなければ、空の文面で控えに載せて `true`。言ってあれば `false`。
    ///
    /// ``SharedWarningLog`` が、**錠の中では「初めてか」の確かめと印だけを行い、文面の組み立てと
    /// 標準エラーへの書き込みを錠の外で行う**ために分けた入口。載せた空の文面は、
    /// ``record(_:_:)`` が言った文面に置き換える。
    mutating func claim(_ key: Key) -> Bool {
        guard said[key] == nil else { return false }
        said[key] = ""
        return true
    }

    /// ``claim(_:)`` で取った鍵に、言った文面を控える。
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
///    先にそれを錠なしで辿る。載っていれば、言うのは別のスレッドが済ませたか、いま言っている最中である
///    (読み出しは取得順序で、載せる側は公開順序なので、載った鍵は必ず見える)
/// 2. **初めての回だけ錠を取る。** 錠の中は「この鍵は初めてか」の確かめと印 (``WarningLog/claim(_:)``)
///    だけで、**文面の組み立てと標準エラーへの書き込みは錠の外**で行う。文面の中から同じ控えの口を
///    呼んでも錠の再入にならず、標準エラーが詰まっても、言わない回を巻き込んで止めない
///
/// 言う権利を取るのは 1 スレッドだけなので、文面の組み立ても 1 度だけである。
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

    private let log = Mutex(WarningLog<Key>())
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
        let isFirst = log.withLock { log in
            guard log.claim(key) else { return false }
            publish(key)
            return true
        }
        guard isFirst else { return }
        let text = message()
        log.withLock { $0.record(key, text) }
        Diagnostics.warn(text)
    }

    /// いま言ってある注意の写し。**検査が読む。**
    var snapshot: WarningLog<Key> { log.withLock { $0 } }
}
