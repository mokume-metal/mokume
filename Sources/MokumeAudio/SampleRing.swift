// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Synchronization

/// 音の標本を溜める環。書き手 1 つ (音の realtime スレッド) と読み手 1 つ (フレーム) の間に置く。
///
/// **書き手は錠を取らず、確保もしない** ([ADR-0042] 決定 7)。realtime スレッドで錠を待つと
/// 音が途切れ、確保は時間の上限が無い。置き場は作るときに 1 度だけ確保し、書き手は標本を
/// 置いてから「書いた総数」を `Atomic` で公開する。読み手はその数を読んでから、手前の窓を写す。
///
/// 読み手が写している間に書き手が 1 周して同じ場所を上書きすると、写した窓が混ざる。容量を
/// 窓の 32 倍にしてあるので、それには写す間に 0.7 秒ぶん (48 kHz で) 書かれる必要があり、
/// フレームの中では起きない。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class SampleRing: @unchecked Sendable {
    // `@unchecked Sendable`: 置き場は書き手だけが書き、読み手は ``written`` を読んだ後に、
    // そこより手前だけを読む (上の説明)。

    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let stamp = Atomic<UInt64>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: - 書き手 (realtime スレッド)

    /// `count` 個の標本を置く。`sample(i)` が i 番目を返す。**錠も確保も無い。**
    ///
    /// - Parameter hostTime: 置いた標本の最後が届いた host time。
    func write(count: Int, hostTime: UInt64, _ sample: (Int) -> Float) {
        let start = written.load(ordering: .relaxed)
        for offset in 0..<count {
            storage[(start + offset) % capacity] = sample(offset)
        }
        stamp.store(hostTime, ordering: .relaxed)
        written.store(start + count, ordering: .releasing)
    }

    // MARK: - 読み手 (フレーム)

    /// これまでに書かれた標本の総数。新しい標本が届いたかを見るのに使う。
    var total: Int { written.load(ordering: .acquiring) }

    /// 最後に書かれた標本が届いた host time。
    var lastHostTime: UInt64 { stamp.load(ordering: .relaxed) }

    /// 最新の `count` 個を、古い順に写す。まだ書かれていない分は前を 0 で埋める。
    func latest(_ count: Int) -> [Float] {
        let end = total
        return (0..<count).map { offset in
            let index = end - count + offset
            return index < 0 ? 0 : storage[index % capacity]
        }
    }
}
