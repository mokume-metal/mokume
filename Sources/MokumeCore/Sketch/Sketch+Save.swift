// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 描いた絵をファイルにする。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    // MARK: - 1 枚

    /// いま描いた絵を 1 枚、ファイルにする。
    ///
    /// ```swift
    /// func draw() {
    ///     background(.display(red: 0.1, green: 0.1, blue: 0.12))
    ///     circle(width / 2, height / 2, 200)
    ///     if frameCount == 1 { save("first.png") }
    /// }
    /// ```
    ///
    /// 途中のディレクトリは無ければ作る。形式は PNG で、色空間は作業空間と同じ
    /// Display P3 ([ADR-0011] 決定 1)。
    ///
    /// ## 出るのは画面と同じ絵である
    ///
    /// 書き出しは**画面へ差し出す絵と同じ道**から受け取る ([ADR-0024] 決定 6)。
    /// 効果も、明るさを写す段も、描く細かさと出す細かさの違いも、画面と同じに効く。
    /// 「画面ではこう見えるのに書き出すと違う」が起こらないのは、道が 1 本しか
    /// 無いからである。
    ///
    /// **透けたところは透けたまま残る。** 出力段がアルファの乗算を戻してから書くので
    /// ([ADR-0011] 決定 4)、``background(_:)`` に ``LinearRGBA/transparent`` を渡した
    /// 絵は、透過を持つ PNG になる。
    ///
    /// ## 書かれるのはこのフレームを描き終えた後
    ///
    /// 呼んだ時点では**予約するだけ**で、実際の書き込みはフレームの外で走る。
    /// ディスクの速さがフレームレートを縛らないためである。頼んだものが確かに
    /// ファイルになっているのは、``endRecord()`` から返った後と、スケッチが
    /// 終わった後である。
    ///
    /// - Parameter path: 書き出す先。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public func save(_ path: String) {
        guard let runtime = runningSketch else {
            Diagnostics.warn("save(\"\(path)\"): スケッチが走っていないので撮れません")
            return
        }
        runtime.save(path)
    }

    // MARK: - 連番

    /// 連番で撮り続ける。
    ///
    /// ```swift
    /// func draw() {
    ///     background(.display(red: 0.1, green: 0.1, blue: 0.12))
    ///     circle(width / 2 + cos(time) * 200, height / 2, 80)
    ///
    ///     if frameCount == 1 { beginRecord("out/frame-####.png") }
    ///     if frameCount == 120 { endRecord() }
    /// }
    /// ```
    ///
    /// **`#` の並びが番号の桁になる。** 桁を揃えるので、名前順に並べたときが撮った順に
    /// なる。番号はこの録りの中での通し番号で、0 から始まる (フレーム番号ではない —
    /// 途中から撮り始めても連番は 0 から続く)。
    ///
    /// `#` が 1 つも無い名前は**撮り始めずに知らせる**。受けてしまうと全部のフレームが
    /// 同じ名前になり、最後の 1 枚しか残らない — 撮れているつもりで撮れていない、という
    /// いちばん分かりにくい壊れ方になる。
    ///
    /// ## 追いつかないときは、フレームが遅くなる
    ///
    /// 書き込みが間に合わないと、抱える枚数が上限に達したところで次のフレームが待つ。
    /// **メモリは伸びない代わりに、絵が遅くなる。** 長い連番を撮っても走らせ続けられる
    /// ことを、伸び続けないことのほうで担保している。
    ///
    /// - Parameter pattern: 番号の場所を `#` で示した行き先 (`"out/frame-####.png"`)。
    public func beginRecord(_ pattern: String) {
        guard let runtime = runningSketch else {
            Diagnostics.warn("beginRecord(\"\(pattern)\"): スケッチが走っていないので撮れません")
            return
        }
        runtime.beginRecord(pattern)
    }

    /// 連番を止める。**頼んだ全部がファイルになってから返る。**
    ///
    /// 「呼んだら書かれる」ように見える面が「あとで書かれる」実装だと、止めるときに
    /// 壊れる。ここから返った後にプロセスを終えても、要求した最後の 1 枚まで残っている。
    /// **始まりだけでなく終わりも面の一部**である。
    ///
    /// 待つのはまだ書けていない枚数ぶんだけなので、撮り終わりに 1 度だけフレームが
    /// 伸びる。
    public func endRecord() {
        guard let runtime = runningSketch else {
            Diagnostics.warn("endRecord(): スケッチが走っていません")
            return
        }
        runtime.endRecord()
    }
}
