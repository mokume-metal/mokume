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
}
