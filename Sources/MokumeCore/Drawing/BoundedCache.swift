// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 上限つきの控え。**面が頼みを鍵にして持つ控えは、どれもこの型で作る** ([ADR-0023] 決定 5)。
/// 面の格納のうち「控え」に分けたものがこの型であることは、`CanvasTests` の格納の表を
/// 確かめる検査が見る。
///
/// この型を通らない控えが 2 つあり、どちらも別の形で上限を持つ。焼き場の字形
/// (``GlyphAtlas``) は面の広さが上限で、満ちたら頁ごと焼き直す ([#1342])。書体の中の字の
/// 引き当て (``Typeface``) は書体 1 つに属し、書体ごとこの型の控えから捨てられる。
///
/// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
///
/// 控えの上限は 2 度書き落とされた。モデルの控え ([#1593]) と書体の控え ([#1431]) で、
/// どちらも落ちも警告も出ず、長く回したときの footprint にしか出なかった。上限・追い出し・
/// 使った時刻の記録を控えごとに書くと、書き落とせる場所が控えの数だけできる ([#1602])。
/// だから 1 つの型に持たせ、**作るときに重さの関数と予算を必ず取る** (既定値は置かない)。
///
/// - 重さは量で数える。件数で切る控えは、重さを 1 にした特別な場合である
/// - 当たると、最後に使った時刻を記録する。**記録しない読み方は置かない** — 読む口は
///   `mutating get` の添字 1 つだけにしてあるので、読めば必ず記録される
/// - 予算を超えたら、古い順に 1 件ずつ捨てて予算以下に戻す
/// - **いま入れたものは、1 つで予算を超えても残す。** そこで空にしても読み直しが増えるだけで、
///   抱える量は減らない (入れた値は呼んだ側が持っている)
/// - 作った回数 (入れた回数) を数える。控えが効いているかを、絵ではなく数で確かめる値
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [#1431]: https://github.com/mokume-metal/mokume/issues/1431
/// [#1593]: https://github.com/mokume-metal/mokume/issues/1593
/// [#1602]: https://github.com/mokume-metal/mokume/issues/1602
struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var weight: Int
        var lastUse: Int
    }

    private var entries: [Key: Entry] = [:]
    /// 使った順の記録。**使うたびに (時刻, 鍵) を末尾へ積み、古い記録は消さない** ([#1780])。
    ///
    /// 追い出す相手は「最後に使った時刻がいちばん古いもの」で、全件を舐めて探すと予算が
    /// 満ちた控えでは入れるたびに件数ぶん走る — 寸法が毎フレーム変わる立体 300 個で、
    /// 1 フレーム 800 ms を超えた。時刻は積む順に増えるので、先頭から読んで**その鍵の
    /// 最後の時刻と一致する記録**が、全件の最小と同じ相手になる (一致しない記録は、あとで
    /// 使い直された古い記録なので読み飛ばす)。
    ///
    /// 読み飛ばす記録が溜まりすぎたら詰め直す (``compactIfNeeded()``)。詰め直しは生きた
    /// 記録の数に比例し、溜まった記録の数に対して償却で O(1) になる。
    ///
    /// [#1780]: https://github.com/mokume-metal/mokume/issues/1780
    private var order: [(time: Int, key: Key)] = []
    /// ``order`` のうち、読み終えた先頭の数。
    private var head = 0
    private var clock = 0
    private let weigh: (Value) -> Int

    /// 控えに置いておく重さの合計。超えたら、収まるまで古い順に捨てる。
    ///
    /// **変えられるのは検査のため** (`Canvas.uploadByteLimit` と同じ扱い)。小さい予算で
    /// 追い出しを確かめる。変えた直後には捨てず、次に入れたときに収める。
    var budget: Int
    /// いま控えている重さの合計。
    private(set) var total = 0
    /// 作った回数 (入れた回数・作ってから通算)。同じ鍵を入れ直しても 1 回と数える。
    private(set) var made = 0

    /// - Parameters:
    ///   - budget: 重さの合計の上限。
    ///   - weight: 値 1 つの重さ。件数で切るなら `{ _ in 1 }` を渡す。
    init(budget: Int, weight: @escaping (Value) -> Int) {
        self.budget = budget
        self.weigh = weight
    }

    /// いま控えている件数。
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// 控えを引く。**当たれば、最後に使った時刻を記録する。**
    subscript(key: Key) -> Value? {
        mutating get {
            guard let entry = entries[key] else { return nil }
            let now = tick()
            entries[key]?.lastUse = now
            order.append((now, key))
            compactIfNeeded()
            return entry.value
        }
    }

    /// 作ったものを入れる。同じ鍵があれば置き換える。
    ///
    /// 予算を超えたら、いま入れたもの以外を古い順に 1 件ずつ捨てて予算以下に戻す。
    mutating func insert(_ value: Value, for key: Key) {
        let weight = weigh(value)
        total -= entries[key]?.weight ?? 0
        let now = tick()
        entries[key] = Entry(value: value, weight: weight, lastUse: now)
        order.append((now, key))
        total += weight
        made += 1
        while total > budget, entries.count > 1, let oldest = popOldest() {
            total -= entries.removeValue(forKey: oldest)?.weight ?? 0
        }
        compactIfNeeded()
    }

    /// 最後に使った時刻がいちばん古い鍵を、使った順の記録から取り出す。
    ///
    /// いま入れたものは記録の末尾にあり、ほかに生きた記録が 1 つでも残っていればそちらが
    /// 先に出る。呼ぶ側は件数が 2 以上のときだけ呼ぶので、いま入れたものは出てこない。
    private mutating func popOldest() -> Key? {
        while head < order.count {
            let (time, key) = order[head]
            head += 1
            if entries[key]?.lastUse == time { return key }
        }
        return nil
    }

    /// 読み飛ばす記録が生きた記録より十分多くなったら、生きた記録だけへ詰め直す。
    ///
    /// 閾値を生きた件数の倍に取るので、詰め直す仕事は、その間に積んだ記録の数で割れば
    /// 定数になる。件数の少ない控えで細かく詰め直さないよう、下駄を履かせる。
    private mutating func compactIfNeeded() {
        guard order.count - head > 2 * entries.count + 64 else { return }
        var live: [(time: Int, key: Key)] = []
        live.reserveCapacity(entries.count)
        for index in head..<order.count {
            let (time, key) = order[index]
            if entries[key]?.lastUse == time { live.append((time, key)) }
        }
        order = live
        head = 0
    }

    private mutating func tick() -> Int {
        defer { clock += 1 }
        return clock
    }
}
