// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 種から同じ列を出す、値として持てる乱数源。Swift 標準の `RandomNumberGenerator` に適合する。
///
/// スケッチの乱数 (``SketchPart/random()``) は 1 本の列で、`init` の中や部品 (`struct`) の中に持ち歩けない。
/// この型は列を**値として持つ** — 部品ごと・花ごとに別の列を作り、他で何回乱数を引いても変わらない。
/// Swift 標準の `Float.random(in:using:)`・`randomElement(using:)`・`shuffled(using:)` にそのまま渡せる。
///
/// <!-- example: 文脈 var flowers: [(x: Float, y: Float, tint: Int)] = []; var showDust = false -->
/// ```swift
/// func setup() {
///     flowers = (0..<200).map { i in
///         var r = RandomSource(seed: 7, index: i)         // 花ごとに独立した列
///         return (x: Float.random(in: 0..<width, using: &r),
///                 y: Float.random(in: 0..<height, using: &r),
///                 tint: [0, 1, 2].randomElement(using: &r)!)
///     }
/// }
///
/// func draw() {
///     background(240)
///     noStroke()
///     // 背景の飾りに乱数を足しても、花は動かない (花は自分の列で決まっている)
///     if showDust { for _ in 0..<50 { point(random(width), random(height)) } }
///     for flower in flowers {
///         fill(flower.tint == 0 ? 240 : 90, flower.tint == 1 ? 200 : 90, flower.tint == 2 ? 220 : 90)
///         circle(flower.x, flower.y, 10)
///     }
/// }
/// ```
///
/// ## 種は必ず渡す
///
/// 作り方は ``init(seed:)`` と ``init(seed:index:)`` だけで、**種の無い `init()` は無い。** 種を時刻から作る
/// 道を置くと、写した作品が走らせるたびに別の絵になり、同じ入力から同じ絵 ([ADR-0001] 原則 2) も、
/// 記録した入力の再生による再現も崩れる。毎回ちがう絵が欲しいときは、変わる値を自分で種に渡す。
///
/// ## 同じ種からは同じ列
///
/// 同じ種から作った乱数源は、同じ順に引けば同じ値を返す。中身はスケッチの乱数 (``SketchPart/random()``) と
/// 同じ生成器 (SplitMix64) で、**``SketchPart/randomSeed(_:)`` を渡したスケッチの列と同じ並びを引く**
/// (`RandomSource(seed: 42)` と `randomSeed(42)` の後の ``SketchPart/randomSource`` は、同じ 64 ビットの
/// 列を出す)。
///
/// ## Swift 標準の口は、これを渡して種に従わせる
///
/// Swift の `randomElement()`・`shuffled()`・`Float.random(in:)` は、引数を省くと種に従わない
/// (`SystemRandomNumberGenerator` で引くので、走らせるたびに絵が変わる)。`using:` にこの型を渡すと、
/// 種に従う。スケッチの列で引くなら ``SketchPart/randomSource``。
///
/// ## 値の型である
///
/// 代入すると写しになる。写した後は別々に進む。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
public nonisolated struct RandomSource: RandomNumberGenerator, Sendable {
    /// 中身の生成器。
    var core: Randomness
    /// スケッチの列から取り出した写しなら、取り出した時点の列の印 (``SketchPart/randomSource`` が書き戻すとき、
    /// 続きか・自分で作ったものかを見分ける)。自分で作ったものは、どの列の印とも合わない値。**値には効かない。**
    var origin: UInt64 = .max

    init(core: Randomness, origin: UInt64) {
        self.core = core
        self.origin = origin
    }

    /// 種から乱数源を作る。同じ種からは、いつでも同じ列が出る。
    ///
    /// 種は ``SketchPart/randomSeed(_:)`` と同じ数で、**同じ種なら、スケッチの列と同じ並びを引く**。
    public init(seed: Int) {
        core = Randomness(seed: seed)
    }

    /// 種と番号から、**番号ごとに独立した列**を作る。
    ///
    /// 花ごと・板ごと・部品ごとに別の列が要るときに、番号 (添字や ID) を渡す。同じ種でも番号が違えば別の
    /// 列で、**隣り合う番号 (`0`・`1`・`2` …) や隣り合う種でも、列は重ならず相関しない** — 種に連番を
    /// 足しただけの作り方は、列が 1 つずれただけの同じ列になることがあるが、ここは種と番号を撹拌して
    /// 合わせるので、そうならない。
    ///
    /// 引く順に依らない: 番号 12 の列は、番号 0〜11 を先に引いたかどうかに関わらず同じ。
    public init(seed: Int, index: Int) {
        core = Randomness(seed: seed, index: index)
    }

    /// 次の 64 ビット。`RandomNumberGenerator` の要件で、Swift 標準の乱数の口が引く。
    public mutating func next() -> UInt64 {
        core.next()
    }
}
