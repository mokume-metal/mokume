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
}
