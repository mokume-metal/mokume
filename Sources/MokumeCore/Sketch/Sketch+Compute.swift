// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 描く前の計算。
extension Sketch {
    /// 数の並びを用意する。**CPU と GPU で同じものを見る。**
    ///
    /// <!-- example: 文脈 var heat: Numbers! -->
    /// ```swift
    /// heat = try? makeNumbers(count: 4096)
    /// heat.fill(0)
    /// ```
    ///
    /// ## 書くのは CPU から、読むのは 1 本の道から
    ///
    /// 書くのはいつでもよい。種を蒔く向き (CPU → GPU) はフレームの外でも中でも意味が
    /// 変わらないので、`setup()` で蒔いてから `draw()` で回してよい。
    ///
    /// **読むときは ``read(_:)`` を通る。** この型に読む口は無く、そこは必ず計算の
    /// 完了まで待つ。同じメモリを見ているので値は「読めて」しまうが、それが計算の前なのか
    /// 後なのかは呼んだ側に分からず、**絵か音がおかしくなって初めて気付く**形になるため。
    ///
    /// - Throws: 領域を取れないときに ``RenderFailure``。
    public func makeNumbers(count: Int) throws(RenderFailure) -> Numbers {
        try canvas.makeNumbers(count: count)
    }

    /// 文字列から計算を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// <!-- example: 文脈 var step: Computation! -->
    /// ```swift
    /// step = try? makeComputation(
    ///     """
    ///     kernel void step(device float *heat [[buffer(0)]],
    ///                      constant Values &values [[buffer(MOKUME_VALUES)]],
    ///                      uint id [[thread_position_in_grid]])
    ///     {
    ///         heat[id] = 0.5 + 0.5 * sin(float(id) * 0.01 + values.time);
    ///     }
    ///     """,
    ///     name: "step", values: ["time": 0])
    /// ```
    ///
    /// ## 入口の関数は名前と同じ
    ///
    /// `name` がそのまま断片の中の `kernel void <name>(...)` になる。読み込む側
    /// (``loadComputation(_:values:)``) ではファイル名がその名前になる。
    ///
    /// ## 束ねる先は呼ぶときに決まる
    ///
    /// ``compute(_:over:reads:writes:)`` に渡した `reads + writes` の並びが、そのまま
    /// `buffer(0)`, `buffer(1)`, … になる。渡した値は `MOKUME_VALUES` の口に載る
    /// (番号を書き写さずに済むよう名前で配ってある)。値は後から差し替えられる
    /// (``Computation/set(_:_:)``)。
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても計算は止まらない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    public func makeComputation(
        _ body: String, name: String = "computation", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.makeComputation(body, name: name, values: values)
    }

    /// ファイルから計算を読み込む。**入口の関数の名前はファイル名**になる。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    public func loadComputation(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.loadComputation(path, values: values)
    }

    /// 描く前に計算させる (1 次元)。
    ///
    /// <!-- example: 文脈 var step: Computation! -->
    /// <!-- example: 文脈 var seed: Numbers! -->
    /// <!-- example: 文脈 var heat: Numbers! -->
    /// ```swift
    /// func draw() {
    ///     compute(step, over: 4096, reads: [seed], writes: [heat])
    ///     // …heat を読む断片で塗る
    /// }
    /// ```
    ///
    /// ## 読むものと書くものを言う
    ///
    /// `reads` と `writes` は**束ねる先であると同時に、依存の宣言**でもある。前に頼んだ
    /// 計算が書いた並びに触れる計算は、その計算が終わってから走る — 触れない計算どうしは
    /// 並行に走る。**順序は宣言から導かれる**ので、待つ仕掛けを自分で書くことはない。
    ///
    /// 束ねる先と宣言を 1 つにしてあるのは、2 つに分けると「束ねたのに宣言し忘れた」
    /// 組み合わせが作れてしまうからである。
    ///
    /// ## 計算と描画の間
    ///
    /// 計算が書いた並びを描画が読むときの同期も仕組みが入れる。**頼まれていない
    /// フレームでは何も待たない**ので、計算を使わないスケッチが遅くなることはない。
    ///
    /// ## 描くところで頼む
    ///
    /// `draw()` の中だけで効く。`setup()` や初期化から頼んだ計算はどのフレームにも
    /// 属さないので、**無視して理由を知らせる**。
    public func compute(
        _ computation: Computation, over count: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: count, reads: reads, writes: writes)
    }

    /// これから描くものが、この並びを読む。
    ///
    /// 断片からは `in.numbers[i]` で引ける。**計算が書いた値をそのまま絵にする道**で、
    /// 渡していない断片が読むと 1 個の 0 が返る (何も束ねない状態は作らない)。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が後から
    /// 差し替わることはない。長さは渡した側が知っているので断片へは配らない。
    public func numbers(_ numbers: Numbers) { canvas.numbers(numbers) }

    /// 並びを読まない状態へ戻す。
    public func resetNumbers() { canvas.resetNumbers() }

    /// 描く前に計算させる (2 次元)。
    ///
    /// 断片は `uint2 at [[thread_position_in_grid]]` で位置を受け取る。ほかは 1 次元の
    /// ``compute(_:over:reads:writes:)`` と同じ。
    public func compute(
        _ computation: Computation, over width: Int, by height: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: width, by: height, reads: reads, writes: writes)
    }

    /// 計算が書いた値を読む。**そのフレームの結果が返る。**
    ///
    /// <!-- example: 文脈 var loudness: Computation! -->
    /// <!-- example: 文脈 var wave: Numbers! -->
    /// <!-- example: 文脈 var level: Numbers! -->
    /// ```swift
    /// func draw() {
    ///     compute(loudness, over: 4096, reads: [wave], writes: [level])
    ///     let values = read(level)      // ここで走らせて待つ
    ///     circle(width / 2, height / 2, values[0] * 200)
    /// }
    /// ```
    ///
    /// GPU で集めた値を、音・通信・状態遷移といった CPU 側の仕事へ渡すための道である。
    ///
    /// ## 読むと、そのフレームの続きが止まる
    ///
    /// 頼んだ計算がまだ走っていなければ、**その場で走らせて GPU の完了まで待つ**。
    /// 待っているあいだ、このフレームの続き (残りの図形を置くことも、描き切ることも)
    /// は進まない。毎フレーム読むと CPU と GPU が交互に動く形になり、重なって進めなく
    /// なる — **読むのは要るときだけ・まとめて 1 度**にする。
    ///
    /// 頼んだ計算が残っていなければ待ちは起きない。走らせたものはコマンドの完了まで
    /// 待ってから返っているので、**溜まっていない = 全部終わっている**が成り立つ。
    /// 同じフレームで 2 度読んでも、待つのは 1 度きり。
    ///
    /// ## 溜めている図形には触らない
    ///
    /// 画素の読み戻し (``pixels``) は溜めている図形を描き切るが、こちらは計算だけを
    /// 流す。図形を 1 つも置いていないフレームでも読めるし、読んだあとに置いた図形が
    /// 消えることもない。**別の機能を有効にしたときだけ動く形にしない**ため、同期を
    /// ほかの経路の副作用に相乗りさせていない。
    ///
    /// ## 読んだ後にもう一度頼んでよい
    ///
    /// 読んだ時点で溜め場は空になる。そのあと頼んだ計算は、いつもどおり描く前に流れる。
    /// 同じ計算が 2 度走ることはない。
    public func read(_ numbers: Numbers) -> [Float] { canvas.read(numbers) }
}
