// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// いまの値を観測へ差し出す。
    ///
    /// ```swift
    /// func draw() {
    ///     let angle = time * 0.5
    ///     expose("angle", angle)
    ///     circle(width / 2 + cos(angle) * 100, height / 2, 40)
    /// }
    /// ```
    ///
    /// 差し出した値は、その絵を撮った観測の応答に**そのフレームの値として**載る。
    /// 絵とスケッチの内部の数字が 1 回の書き出しで揃うので、読み手は 2 つのファイルを
    /// 読む間合いに賭けずに「この絵はどの値のときのものか」を確定できる。
    ///
    /// **差し出した値はそのフレームかぎりで、次のフレームの頭で消える。** 載せ続けたい
    /// 値は毎フレーム差し出し直す。`setup()` の中で差し出した値も、最初のフレームの頭で
    /// 消える。
    ///
    /// 例外は ``measure(_:_:)`` で測った値で、**測り直すまで、実行がフレームの頭で差し出し
    /// 直す**。だから応答の `values` は、そのフレームで差し出した値に、前に測って残っている
    /// 値を含む。同じフレームで測った値と同じ名前を差し出すと、そのフレームだけはこちらが
    /// 載る。
    ///
    /// **観測が有効でないときは何もしない。** 走らせるたびに払うものが無いので、
    /// 描画の中に置いたままにしてよい。走っていないとき (init やプロパティの初期化子)
    /// も黙って何もしない — 観測は本体の挙動を変えない。
    public func expose(_ name: String, _ value: Double) {
        runningSketch?.expose(name, .float(value))
    }

    /// いまの値を観測へ差し出す。
    public func expose(_ name: String, _ value: Float) {
        runningSketch?.expose(name, .float(Double(value)))
    }

    /// いまの値を観測へ差し出す。
    public func expose(_ name: String, _ value: Int) {
        runningSketch?.expose(name, .int(value))
    }

    /// いまの値を観測へ差し出す。
    public func expose(_ name: String, _ value: String) {
        runningSketch?.expose(name, .string(value))
    }

    /// いまの値を観測へ差し出す。
    public func expose(_ name: String, _ value: Bool) {
        runningSketch?.expose(name, .bool(value))
    }

    /// 処理を 1 度走らせ、かかった実時間 (ミリ秒) を観測へ差し出す。
    ///
    /// 準備の重さ — 形を組む・焼く・数える — を、観測の応答で読むための口である。処理の
    /// 戻り値はそのまま返り、処理が投げればそのまま伝わる。
    ///
    /// <!-- example: 文脈 var heights: [Float] = [] -->
    /// ```swift
    /// if heights.isEmpty {
    ///     heights = measure("raiseMs") {
    ///         (0..<4096).map { noise(Float($0) * 0.01) * 200 }
    ///     }
    /// }
    /// ```
    ///
    /// 値は `name` の名前で応答の `values` に、ミリ秒の実数として載る。**同じ名前で測り
    /// 直すまで、どのフレームの応答にも載る** — 準備を 1 度だけ測れば、あとのフレームで
    /// 差し出し直さなくてよい。`setup()` の中で測った値も、最初のフレームの応答に載る。
    /// 同じフレームで同じ名前を ``expose(_:_:)-(_,Double)`` すると、そのフレームだけは
    /// そちらが載る。
    ///
    /// **値は走らせるたびに違い、絵には入らない。** かかった時間はスケッチへ返さないので、
    /// 描く値に実時間が混ざらない ([ADR-0025] の水準に触れない)。2 回の実行を値で突き
    /// 合わせる検査には使わない。時間で絵を動かすなら ``time`` を読む — フレームの時刻で、
    /// フレームの途中では進まないので、区間を測るのには使えない。
    ///
    /// 手本 (Processing・p5.js) は `millis()` の差で測る。mokume が `millis()` を持たないのは、
    /// 起動からの実時間を返す口は描く値にも使えてしまい、再現する時計 (書き出しや検査が
    /// 使う、フレーム番号から時刻を導く時計) の下でも実時間で動く絵を黙って作るためである。
    /// 測る用途はこの口で足りる。
    ///
    /// **観測が有効でなくても、処理は必ず 1 度走る。** そのときは時計を読まず、何も溜め
    /// ない。走っていないとき (init やプロパティの初期化子) も、処理だけを走らせる。処理が
    /// 投げたときは値を差し出さない — 前に同じ名前で測った値があれば、それが残る。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard let runtime = runningSketch else { return try body() }
        return try runtime.measure(name, body)
    }
}
