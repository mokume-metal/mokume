// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 粒。
extension Sketch {
    /// 粒を用意する。**同時に持てる数をここで決める。**
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func setup() {
    ///     dust = try? makeParticles(count: 20000)
    /// }
    /// ```
    ///
    /// ## 混ぜ方は、作った瞬間に決まる
    ///
    /// 粒の板は保持した形 (``createShape(_:)``) なので、**これを呼んだ瞬間の混ぜ方が
    /// 粒に焼き付く。** `draw()` で後から ``blendMode(_:)`` を呼んでも、粒には効かない。
    /// 色は焼き付かない — 粒ごとに ``emit(_:from:rate:speed:angle:life:size:color:)`` が渡す。
    ///
    /// 加算で光らせるなら、作る前に混ぜ方を置く。作ったあとは戻してよい — 粒が持ち歩く
    /// のは作った瞬間の値で、外の状態は作る前と変わらない。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func setup() {
    ///     blendMode(.add)
    ///     dust = try? makeParticles(count: 20000)
    ///     blendMode(.blend)
    /// }
    /// ```
    ///
    /// ## 枠は環状に回る
    ///
    /// 出した粒は空いている枠へ順に入り、末尾まで行くと先頭へ戻る。**まだ生きている粒を
    /// 上書きしたときは理由を知らせる** — 出す数 (`rate`) × 寿命 (`life`) がここで決めた
    /// 数より多いと起きるので、どれかを変える。
    ///
    /// ## 大きすぎる数
    ///
    /// 置き場を取れない数は**確保の失敗として返る**。途中まで作って止まることはない。
    ///
    /// - Throws: 置き場を取れないときに ``RenderFailure``。
    public func makeParticles(count: Int) throws(RenderFailure) -> Particles {
        try canvas.makeParticles(count: count)
    }

    /// 粒を出す。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// func draw() {
    ///     emit(dust, from: .point(width / 2, 40), rate: 600, life: 1...2.5)
    ///     force(dust, .gravity(0, 90), .drag(0.4))
    ///     particles(dust)
    /// }
    /// ```
    ///
    /// ## 低いレートでも、長い目で見て頼んだ数が出る
    ///
    /// `rate` は**毎秒**の数で、1 フレームぶんに割ると端数が出る。端数は捨てずに繰り越す
    /// ので、毎秒 1 個未満でもいつかは出る。捨てる作りにすると、**低いレートで 1 個も
    /// 出ない**が起き、しかも 1 枚の絵では見えない。
    ///
    /// ## 出る場所と飛ぶ向きは別
    ///
    /// `from` が出る場所を、`angle` が飛ぶ向き (画面の面内・ラジアン) を決める。形を
    /// 差し替えても向きは変わらない。
    ///
    /// ## 何もかも幅で指定する
    ///
    /// `speed` / `life` / `size` は幅で渡す。1 つに決めたいときは `2...2` のように書く。
    /// `color` を省くと、そのときの塗りで出る。
    ///
    /// 出た粒の値は**種から決まる乱数** (``random()`` と同じ 1 本の流れ) で引くので、
    /// ``randomSeed(_:)`` を決めれば何度走らせても同じ粒が出る。
    public func emit(
        _ particles: Particles, from source: Emitter, rate: Float,
        speed: ClosedRange<Float> = 20...60,
        angle: ClosedRange<Float> = 0...(2 * Float.pi),
        life: ClosedRange<Float> = 1...2,
        size: ClosedRange<Float> = 2...6,
        color: LinearRGBA? = nil
    ) {
        let runtime = Self.requireRuntime()
        canvas.emit(
            particles, from: source, rate: rate, speed: speed, angle: angle, life: life,
            size: size, color: color, using: &runtime.randomness)
    }

    /// 粒に力を効かせる。
    ///
    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// force(dust, .gravity(0, 90), .swirl(width / 2, height / 2, strength: 40), .drag(0.6))
    /// ```
    ///
    /// **積んだぶんが、次に進めるときにまとめて効く。** ``particles(_:)`` を呼ぶと空に
    /// なるので、毎フレーム書いてよい。1 回に効かせられるのは 8 個までで、超えたぶんは
    /// 理由を添えて捨てる。
    ///
    /// 引く力 (``Force/attract(_:_:_:strength:)``) は強さを負にすると押す力になる。
    /// 読みやすさのために ``Force/repel(_:_:_:strength:)`` も置いてあるが、**計算は
    /// 同じ 1 本**である。
    public func force(_ particles: Particles, _ forces: Force...) {
        canvas.force(particles, forces)
    }

    /// 粒を 1 フレーム進めて描く。
    ///
    /// **呼ばなければ進まない。** 進めるのと描くのを分けていないのは、「進めたのに
    /// 描いていない粒」と「描いたのに進んでいない粒」という 2 つの状態を作らないため。
    ///
    /// ## 寿命が尽きた粒は描かれない
    ///
    /// 描く個数は GPU が数える。生きている粒だけを枠の番号順に詰めて描くので、枠を
    /// 大きく取っても、払うのは生きている粒のぶんだけである。
    ///
    /// ## 進むのは 1 フレームぶん
    ///
    /// 進む量は ``deltaTime`` で決まる。時計をフレーム番号から導く走らせ方 (ヘッドレスの
    /// 書き出し) なら刻みが一定なので、**同じ入力から何度走らせても同じ動き**が出る。
    ///
    /// ## 粒は、どこから見ても画面に正対する
    ///
    /// 粒 1 つは四角い板で、**板は常に画面の面と平行に置かれる。** ``orbitControl(_:_:_:)``
    /// や ``camera(_:_:_:_:_:_:_:_:_:)`` で視点を真横へ回しても、``rotateY(_:)`` で雲ごと
    /// 回しても、粒は横を向いて痩せない。
    ///
    /// 位置には変換がそのまま効く。変換から板が受け取るのは**倍率だけ**で、回転は板の向きに
    /// 効かない — 平面で ``rotate(_:)`` してから描いても、粒の位置は回るが四角は傾かない。
    public func particles(_ particles: Particles) { canvas.particles(particles) }
}
