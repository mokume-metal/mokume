// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 上限つきの控えの検査 ([#1602])。GPU を要さない。
///
/// 面の控え (絵・モデル・立体の形と稜線・書体) はどれもこの型に載るので、**追い出しの
/// 振る舞いはここで 1 度だけ見る**。控えごとの検査が見るのは、予算と重さの選び方である。
///
/// [#1602]: https://github.com/mokume-metal/mokume/issues/1602
@Suite("上限つきの控え")
struct BoundedCacheTests {
    /// 重さを値そのものとする控え。
    private func weighted(budget: Int) -> BoundedCache<String, Int> {
        BoundedCache(budget: budget) { $0 }
    }

    @Test("予算を超えるまで入れても、合計は予算以下に収まる")
    func theTotalStaysWithinTheBudget() {
        var cache = weighted(budget: 10)
        for index in 0..<20 {
            cache.insert(3, for: "\(index)")
            #expect(cache.total <= 10, "\(index + 1) 件入れた後の合計が \(cache.total)")
        }
        // 3 件 (9) で収まる。**1 件ずつ捨てる** — 半分捨てると、予算に収まる分まで捨てる
        #expect(cache.count == 3)
        #expect(cache.total == 9)
    }

    @Test("件数で切る控えは、重さ 1 の特別な場合である")
    func countingIsWeightOne() {
        var cache = BoundedCache<Int, String>(budget: 64) { _ in 1 }
        for index in 0..<1000 { cache.insert("\(index)", for: index) }
        #expect(cache.count == 64)
        // 残っているのは最後の 64 件
        #expect(cache[999] == "999")
        #expect(cache[936] == "936")
        #expect(cache[935] == nil)
    }

    @Test("途中で使い直したものは捨てられない")
    func recentlyUsedEntriesSurvive() {
        var cache = weighted(budget: 10)
        cache.insert(3, for: "kept")
        cache.insert(3, for: "a")
        cache.insert(3, for: "b")
        // いちばん古い "kept" を使い直してから、予算を超えるものを入れる
        #expect(cache["kept"] == 3)
        cache.insert(3, for: "c")
        #expect(cache["kept"] == 3, "使い直したのに捨てられた (入れた順に捨てている)")
        #expect(cache["a"] == nil, "使っていない中でいちばん古いものが残っている")

        // 何度入れ替わっても、1 回おきに使うものは残る
        for index in 0..<50 {
            cache.insert(3, for: "other-\(index)")
            #expect(cache["kept"] == 3, "\(index) 件目で捨てられた")
        }
    }

    @Test("1 つで予算を超えるものも、いま入れたものは残る")
    func anOversizedEntryIsKept() {
        var cache = weighted(budget: 10)
        cache.insert(3, for: "small")
        cache.insert(25, for: "huge")
        #expect(cache["huge"] == 25)
        #expect(cache["small"] == nil, "予算を超えたのに、他のものを捨てていない")
        #expect(cache.count == 1)
        #expect(cache.total == 25)

        // 次に入れたものに押し出される
        cache.insert(3, for: "next")
        #expect(cache["huge"] == nil)
        #expect(cache.total == 3)
    }

    @Test("作った回数を数える。当たっても数えず、入れ直せば数える")
    func insertionsAreCounted() {
        var cache = weighted(budget: 10)
        #expect(cache.made == 0)
        cache.insert(1, for: "a")
        cache.insert(1, for: "b")
        _ = cache["a"]
        _ = cache["missing"]
        #expect(cache.made == 2)
        // 入れ直すと重さは二重に数えない
        cache.insert(4, for: "a")
        #expect(cache.made == 3)
        #expect(cache.total == 5)
        #expect(cache.count == 2)
    }
    // MARK: - 追い出す順番 (#1780)

    /// **全件を舐める素朴な控え**と、同じ操作列で中身が一致し続ける ([#1780])。
    ///
    /// 追い出しを「使った順の記録」から取り出す形に変えたので、順番が全件の最小を探して
    /// いた頃と 1 件でも食い違えば、どこかの時点で残る鍵の集合がずれる。入れる・引く・
    /// 入れ直す・予算を変えるを混ぜる。
    ///
    /// **鍵が少なく予算が大きい組は、記録の詰め直しを走らせるためにある** — 追い出しが
    /// 起きないまま引き当てが続くと、読み飛ばす記録だけが溜まって詰め直しに入る。鍵が多く
    /// 予算が小さい組では、追い出しが古い記録を先に読み進めるので詰め直しに届かない。
    ///
    /// [#1780]: https://github.com/mokume-metal/mokume/issues/1780
    @Test(
        "追い出す順番が、全件を舐めて最も古いものを捨てる控えと一致する",
        arguments: [(keys: 64, budget: 40), (keys: 12, budget: 400)])
    func evictionOrderMatchesTheNaiveCache(keys: UInt64, budget: Int) {
        var cache = weighted(budget: budget)
        var naive = NaiveCache(budget: budget)
        var random = SplitMix(seed: 1780)

        for step in 0..<20_000 {
            let key = "k\(random.next() % keys)"
            switch random.next() % 10 {
            case 0..<5:
                let weight = Int(random.next() % 9) + 1
                cache.insert(weight, for: key)
                naive.insert(weight, for: key)
            case 5..<9:
                #expect(cache[key] == naive[key], "\(step) 手目: \(key) の引き当てが違う")
            default:
                // 予算を変えた直後には捨てず、次に入れたときに収める
                let changed = Int(random.next() % UInt64(budget + budget / 2)) + 1
                cache.budget = changed
                naive.budget = changed
            }
            guard cache.count == naive.count, cache.total == naive.total,
                cache.made == naive.made
            else {
                let counts = "件数 \(cache.count) / \(naive.count)"
                let totals = "合計 \(cache.total) / \(naive.total)"
                Issue.record("\(step) 手目で食い違った: \(counts)、\(totals)")
                return
            }
        }
        // 最後に全部の鍵で中身を比べる (引くと時刻が進むので、両方を同じ順で引く)
        for index in 0..<keys {
            let key = "k\(index)"
            #expect(cache[key] == naive[key], "\(key) の中身が違う")
        }
    }

    /// 比べる相手。**変える前の追い出しをそのまま書いたもの** — 全件から最後に使った
    /// 時刻の最も古いものを探して捨てる。
    private struct NaiveCache {
        var budget: Int
        private var entries: [String: (value: Int, lastUse: Int)] = [:]
        private var clock = 0
        private(set) var made = 0
        var count: Int { entries.count }
        var total: Int { entries.values.reduce(0) { $0 + $1.value } }

        init(budget: Int) { self.budget = budget }

        subscript(key: String) -> Int? {
            mutating get {
                guard let entry = entries[key] else { return nil }
                let now = tick()
                entries[key]?.lastUse = now
                return entry.value
            }
        }

        mutating func insert(_ value: Int, for key: String) {
            let now = tick()
            entries[key] = (value, now)
            made += 1
            while total > budget, entries.count > 1,
                let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            {
                entries.removeValue(forKey: oldest)
            }
        }

        private mutating func tick() -> Int {
            defer { clock += 1 }
            return clock
        }
    }

    /// 検査の中だけで使う決まった乱数列。
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
