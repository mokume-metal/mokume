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
    ///     background(26, 26, 31)
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
    /// ([ADR-0011] 決定 4)、``background(_:)-(LinearRGBA)`` に ``LinearRGBA/transparent`` を渡した
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

    // MARK: - 連番と動画

    /// 撮り続ける。**行き先の綴りが形を決める。**
    ///
    /// ```swift
    /// func draw() {
    ///     background(26, 26, 31)
    ///     circle(width / 2 + cos(time) * 200, height / 2, 80)
    ///
    ///     if frameCount == 1 { beginRecord("out/motion.mov") }  // 動きを 1 本にする
    ///     if frameCount == 120 { endRecord() }
    /// }
    /// ```
    ///
    /// `.mov` で終わる名前なら 1 本の動画に、`#` を含む名前なら 1 枚ずつの連番になる
    /// (`"out/frame-####.png"`)。どちらでもない名前は**撮り始めずに知らせる**。
    ///
    /// ## 連番 — 番号は撮った順に並ぶ
    ///
    /// **`#` の並びが番号の桁になる。** 桁を揃えるので、名前順に並べたときが撮った順に
    /// なる。番号はこの録りの中での通し番号で、0 から始まる (フレーム番号ではない —
    /// 途中から撮り始めても連番は 0 から続く)。
    ///
    /// 番号の入る場所が無い名前を受けてしまうと全部のフレームが同じ名前になり、最後の
    /// 1 枚しか残らない — 撮れているつもりで撮れていない、といういちばん分かりにくい
    /// 壊れ方になる。だから断る。
    ///
    /// ## 動画 — 同じ入力からは同じ動きが出る
    ///
    /// 符号化は ProRes 4444 (.mov) で固定で、選べない。**選べる形にすると、書き出した
    /// 動きが再現するかどうかが名前の付け方で変わる** ([ADR-0025] 決定 3)。同じ入力から
    /// 2 回書き出して測ると、H.264 は画素が一致せず、ProRes 4444 はファイルのバイトまで
    /// 一致した。代わりに**大きい** (480x270 の 90 枚で 3 MB ほど。中身で変わる) —
    /// 配布する形式ではなく、元にする形式である。
    ///
    /// **透けたところは透けたまま残る** (静止画と同じ)。
    ///
    /// 時刻は**そのフレーム自身の時刻**から作る。描けなかったフレームがあっても残った絵の
    /// 時刻は動かず、その 1 枚が長く映るだけになる — 詰めて並べると、動きが少しずつ
    /// 早回しになる。入らなかった枚数は ``endRecord()`` のときに知らせる。
    ///
    /// 時計が実時間なら (画面に出しながら走らせる経路) 実時間のまま入る。同じ動画をもう
    /// 一度出したいなら、フレーム番号から時刻を導く時計で走らせる ([ADR-0025] 決定 1)。
    ///
    /// ## 追いつかないときは、フレームが遅くなる
    ///
    /// 書き込みが間に合わないと、抱える枚数が上限に達したところで次のフレームが待つ。
    /// **メモリは伸びない代わりに、絵が遅くなる。** 長く撮っても走らせ続けられることを、
    /// 伸び続けないことのほうで担保している。
    ///
    /// - Parameter pattern: 行き先。`.mov` なら動画、`#` を並べれば連番。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    public func beginRecord(_ pattern: String) {
        guard let runtime = runningSketch else {
            Diagnostics.warn("beginRecord(\"\(pattern)\"): スケッチが走っていないので撮れません")
            return
        }
        runtime.beginRecord(pattern)
    }

    /// 連番や動画を止める。**頼んだ全部がファイルになってから返る。**
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
