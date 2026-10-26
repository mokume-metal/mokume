// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Synchronization

/// 音の標本を、書き手 1 つ (realtime) と読み手 1 つ (フレーム) の間で渡す。
///
/// 事前に確保した 3 面を、書き手・読み手・交換場所で 1 つずつ所有する (#2916)。
/// 書き手は完成した面を交換場所へ公開し、そこにあった面を次に使う。読み手も交換してから
/// 写すので、写している面は書き手へ戻らない。読み手が何秒止まっても、書き手は残りの
/// 2 面で進める。容量や読み取り時間を安全性の根拠にしない。
///
/// 書き手は前の公開面から、再利用する面に足りない履歴だけを写す (最大 capacity 個)。
/// 前の公開面も、その書き手が次に取り戻すまでは不変で、読み手は書かない。
/// write は確保・ロック待ち・再試行をしない (ADR-0042 決定 7)。
nonisolated final class SampleRing: @unchecked Sendable {
    // @unchecked Sendable: back / published は書き手だけ、front は読み手だけが触る。
    // 面への書き込みは back だけ。middle.exchange の release が公開/読み終わりを、
    // acquire が受領/再利用を順序付ける。破棄は双方の利用が終わってからである。
    let capacity: Int
    private let windows: [Window]
    private var back = 0
    private var front = 1
    private var published = 2
    private let middle = Atomic<Int>(2)
    private let written = Atomic<Int>(0)
    private static let unread = 4

    /// 読み手へ渡す写し。標本と時刻は必ず同じ公開面から取る。
    struct Snapshot: Sendable {
        let samples: [Float]
        let total: Int
        let hostTime: UInt64
    }

    private final class Window {
        let storage: UnsafeMutablePointer<Float>
        var total = 0
        var hostTime: UInt64 = 0

        init(capacity: Int) {
            storage = .allocate(capacity: capacity)
            storage.initialize(repeating: 0, count: capacity)
        }

        deinit { storage.deallocate() }
    }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        windows = (0..<3).map { _ in Window(capacity: capacity) }
    }

    /// count 個を置いて公開する。sample は書き手の上で 1 個につき 1 回呼ぶ。
    func write(count: Int, hostTime: UInt64, _ sample: (Int) -> Float) {
        precondition(count >= 0)
        let previous = windows[published]
        let next = windows[back]
        let start = previous.total
        let end = start + count
        // 新しい書き込みで消える履歴は写さない。再利用する面が既に持つ履歴も写さない。
        let missing = max(next.total, end - capacity)
        if missing < start {
            for index in missing..<start {
                next.storage[index % capacity] = previous.storage[index % capacity]
            }
        }
        for offset in 0..<count {
            next.storage[(start + offset) % capacity] = sample(offset)
        }
        next.total = end
        next.hostTime = hostTime
        published = back
        back = middle.exchange(back | Self.unread, ordering: .acquiringAndReleasing) & ~Self.unread
        written.store(end, ordering: .releasing)
    }

    /// 更新の有無だけを安く調べる。標本と組にする総数は snapshot から読む。
    var total: Int { written.load(ordering: .acquiring) }

    /// 最新の count 個。まだ書かれていない分を前の 0 で埋め、古い順に写す。
    ///
    /// **本番は使わない** (解析は ``snapshot(since:)`` で、前のフレーム以後の区間を写す)。検査が、出口の標本を直に読むのに使う。
    func latest(_ count: Int) -> [Float] { snapshot(count).samples }

    /// 最新の公開面を受け取る。読み手は 1 つだけで、再入しない。
    private func acquireFront() -> Window {
        if middle.load(ordering: .acquiring) & Self.unread != 0 {
            front = middle.exchange(front, ordering: .acquiringAndReleasing) & ~Self.unread
        }
        return windows[front]
    }

    /// 前の読み取りの総数 `previous` 以後に書かれた標本を、解析する区間として写す (最大 `AudioAnalysis.maxSpan`
    /// 標本。足りない前の履歴は、解析が最初の窓の頭まで読むぶんを添える)。
    ///
    /// 総数は面を受け取った後で決まるので、区間の終わり (`span.to`) は、この呼び出しで読んだ総数になる。
    /// 呼ぶ側が先に読んだ ``total`` とは、書き手が進んでいれば違う。読み手は 1 つだけで、再入しない。
    func snapshot(since previous: Int) -> (span: AudioSpan, hostTime: UInt64) {
        let window = acquireFront()
        let to = window.total
        // 容量から溢れて書き換わった古い標本は読まない
        let from = max(min(AudioAnalysis.limited(from: previous, to: to), to), to - capacity)
        let first = max(AudioAnalysis.firstNeeded(from: from), to - capacity, 0)
        let samples = (first..<to).map { window.storage[$0 % capacity] }
        return (AudioSpan(base: first, samples: samples, from: from), window.hostTime)
    }

    /// 標本・総数・hostTime を一緒に写す。読み手は 1 つだけで、再入しない。
    ///
    /// **本番は使わない** (``snapshot(since:)`` が同じ面の受け取り方をする)。検査が、面を取り合う書き手と読み手の安全を
    /// 見るのに使う。
    /// afterAcquiring は、検査が面を受け取った直後で読み手を止めるための口 (#2916)。
    func snapshot(_ count: Int, afterAcquiring: () -> Void = {}) -> Snapshot {
        precondition((0...capacity).contains(count))
        let window = acquireFront()
        afterAcquiring()
        let samples = (0..<count).map { offset in
            let index = window.total - count + offset
            return index < 0 ? 0 : window.storage[index % capacity]
        }
        return Snapshot(samples: samples, total: window.total, hostTime: window.hostTime)
    }
}
