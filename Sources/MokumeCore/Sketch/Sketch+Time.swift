// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 描画を止めずに、時刻だけを止める・再開する・飛ぶ ([#1286])。**説明文の正本はこちら**
// ([ADR-0020] 決定 4)。
//
// 手本 (Processing / p5) の本体には無い口で、同義の手本は Processing Video の
// `Movie.pause()` / `play()` / `jump()` である。`Sketch` の上で裸の `pause()` / `play()` は
// 描画を止める・音を鳴らすと読み違えるので、手本の動詞に対象の `Time` を付けた
// (ADR-0020 決定 1 — 手本の無いものは Swift の慣行に従う)。
//
// [#1286]: https://github.com/mokume-metal/mokume/issues/1286
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension SketchPart {

    /// 次のフレームから、``time`` を止める。**描画は止めない** — ``Sketch/draw()`` は回り続け、
    /// ``frameCount`` も進む。
    ///
    /// 絵を ``time`` の関数として書いておけば、再生位置を自分の変数で持たずに、止める・
    /// 飛ぶ・擦ることができる。物差し (秒か拍か) と操作は作品の側で決める。
    ///
    /// ```swift
    /// var paused = false
    /// let acts: [Float] = [0, 2.0, 6.5, 11.0]  // 幕の頭 (秒)
    ///
    /// func draw() {
    ///     background(0)
    ///     circle(width / 2 + sin(time) * 200, height / 2, 40)  // time だけを読む
    /// }
    ///
    /// func keyPressed() {
    ///     switch keyCode {
    ///     case .space:
    ///         paused.toggle()
    ///         if paused { pauseTime() } else { playTime() }
    ///     case .arrowLeft: jumpTime(time - 0.25)
    ///     case .arrowRight: jumpTime(time + 0.25)
    ///     case .digit1: jumpTime(acts[0])
    ///     case .digit2: jumpTime(acts[1])
    ///     default: break
    ///     }
    /// }
    ///
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     jumpTime(mouseX / width * 12)  // 横位置を 0–12 秒に写して擦る
    /// }
    /// ```
    ///
    /// 止めている間の ``time`` は、**呼んだフレームの値のまま**で、``deltaTime`` は 0 である。
    /// ``deltaTime`` で積んで動かすものも、時刻と一緒に止まる。``playTime()`` で再開すると、
    /// 止めた秒から続ける (止めていた間の実時間へ跳ね戻らない)。既に止めていれば何もしない。
    ///
    /// 時刻を指定した観測 (MCP の `observe` に `{"time": 3}` を渡す) が描き直す 1 枚の中で
    /// 呼んだときだけは、その枚の ``time`` (観測の秒) ではなく、**観測が無ければその枚が持って
    /// いた秒**で止まる。観測は作品の時計に触れず、撮った後は元の時計へ戻るためである。
    ///
    /// ## ``noLoop()`` との違い
    ///
    /// 時刻を指定した観測の枚の ``Sketch/draw()`` の中で、``time`` から作った秒へ `jumpTime(_:)` すると、
    /// ``time`` はその枚だけ観測の秒なので、作者の時計はその秒へ飛ぶ (作者が書いた飛び先であり、
    /// 動作は変えない)。入力のコールバックの中で `jumpTime(time + 0.25)` と書く形は、``time`` が
    /// 作者の時計の秒なので、観測の枚に当たっても作者の時計の秒から飛ぶ。
    ///
    /// ``noLoop()`` は ``Sketch/draw()`` ごと止める。こちらは時刻だけを止め、描画と入力は回り続ける —
    /// 止めた絵の上で擦る UI を動かせる。
    ///
    /// ## 書き出しと作り直し
    ///
    /// 固定の fps で書き出している最中 (`mokume render`) も効く。書き出す枚数は変わらず、
    /// 止めている間の枚は同じ ``time`` の絵が並ぶ。
    ///
    /// **作り直し (watch の世代の乗り換え) をまたいで、止めた秒や飛んだ先は、既定では運ばない。**
    /// 作り直した後も同じ位置で見たいなら、``Sketch/setup()`` で ``jumpTime(_:)`` を呼ぶか、
    /// `mokume watch --keep-time` で見張る。旗を付けると、新しい世代の最初の枚が前の世代の作者の時計の続きから
    /// 始まり (止めていれば止めた秒のまま)、`setup()` の中で読む ``time`` も前の世代の続きの秒になる。`setup()` で
    /// 呼んだ ``pauseTime()``・``playTime()``・``jumpTime(_:)`` は、前の世代が止めていても回っていても、引き継ぎに
    /// 勝つ。`setup()` が時計に触れなければ、最初のフレームを出す時点の前の世代の秒で始め直す (ビルドと起動の間も
    /// 前の世代は回り、止めたり飛んだりもできる)。前の世代が落ちて居なければ、居なかった間は進めず、最後に書いた秒から
    /// 始まる。運ぶのは作者の時計の秒と止めているかだけで、``SketchPart/frameCount``・乱数の列・
    /// ``SketchPart/deltaTime`` で積んだ状態は運ばない。
    ///
    /// ## 呼べる場所
    ///
    /// 進行の口 (``noLoop()`` の「呼べる場所」) と同じで、``Sketch/setup()``・``Sketch/draw()``・入力の
    /// コールバックの中から呼んだときだけ効く。それ以外の場所から呼ぶと何もせず、そのことを
    /// 標準エラーで知らせる。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func pauseTime() {
        guard let runtime = runningSketch else {
            return OutsideRun.log.warn(.pauseTime)
        }
        runtime.pauseTime()
    }

    /// ``pauseTime()`` で止めた ``time`` を、次のフレームから進め直す。
    ///
    /// ```swift
    /// func mouseReleased() {
    ///     playTime()
    /// }
    /// ```
    ///
    /// 再開した最初の 1 枚の ``time`` は、**止めた秒から 1 フレームぶん**進んだ値である
    /// (止めていた間の実時間は乗らない)。``deltaTime`` もふつうの 1 枚ぶんに戻る。
    /// 止めていなければ何もしない。呼べる場所は ``pauseTime()`` と同じ。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func playTime() {
        guard let runtime = runningSketch else {
            return OutsideRun.log.warn(.playTime)
        }
        runtime.playTime()
    }

    /// 次のフレームの ``time`` を `seconds` 秒にする。`seconds` は `Float`・`Double`・`Int` の変数を
    /// そのまま渡せる。
    ///
    /// ```swift
    /// func keyPressed() {
    ///     if keyCode == .digit0 { jumpTime(0) }  // 頭へ戻る
    /// }
    /// ```
    ///
    /// 飛んだ枚の ``deltaTime`` は 0 で、次の枚からは `seconds` から元の刻みで進む。
    /// ``pauseTime()`` で止めている間なら、`seconds` で止まり続ける。同じフレームで何度
    /// 呼んでも、効くのは最後の 1 回である。負の秒も受ける。
    ///
    /// 次のフレームが時刻を指定した観測の 1 枚 (``pauseTime()`` を参照) でも、飛ぶのはその枚で
    /// ある。その枚には観測の秒が描かれるので `seconds` の絵は出ず、その次の枚は観測が無い
    /// ときと同じく `seconds` から 1 フレームぶん進んだ値になる。
    ///
    /// 数でない値 (`.nan`・無限) は受け取らない。時刻は飛ばずにいつもどおり進み (止めて
    /// いれば止めた秒のまま)、「最後の 1 回」にも数えないので、同じフレームで先に頼んだ飛び先が
    /// 効く。受け取らなかったことは 1 度だけ知らせる。
    ///
    /// 描いている最中のフレームの ``time`` は変えない — 1 枚の中で時刻が 2 つあると、
    /// 前半と後半で違う時刻の絵が混ざる。呼べる場所は ``pauseTime()`` と同じ。
    // shot: 撮れない 時刻の進み方を変える口で、1 枚の絵では違いが出ない
    public func jumpTime(_ seconds: some ScalarConvertible) {
        guard let runtime = runningSketch else {
            return OutsideRun.log.warn(.jumpTime)
        }
        runtime.jumpTime(seconds.asFloat)
    }

    /// いまの ``time`` を `period` 秒で 1 巡する位相 (0 以上 1 未満) にして返す。`period` は `Float`・
    /// `Double`・`Int` の変数をそのまま渡せる。
    ///
    /// ```swift
    /// func draw() {
    ///     background(10)
    ///     let p = phase(period: 4)  // 4 秒で 0 から 1 へ巡る
    ///     circle(width / 2, height / 2, 200 + 80 * sin(p * 2 * Float.pi))
    /// }
    /// ```
    ///
    /// **何日走らせても、位相の刻みは粗くならない。** ``time`` は `Float` なので、数日走らせると
    /// 刻みが 60 fps の 1 フレームより粗くなる (``time`` を参照)。この口は時計の中の `Double` の秒から
    /// 余りを取ってから `Float` にするので、刻みは周期の長さで決まる — 4 秒周期なら、1 か月後も
    /// 1 µs より細かい。周期のある動きは `sin(time * 2 * Float.pi / 4)` ではなく、こちらで書く。
    ///
    /// **負の秒も巡る。** ``jumpTime(_:)`` で 0 より前へ飛んだ後も 0 以上 1 未満で、4 秒周期で
    /// `jumpTime(-1)` の直後は 0.75 である。返す値は 1 にならない (1 に丸まるほど周期の終わりに近い値は
    /// 0 を返す)。
    ///
    /// 読む秒は ``time`` と同じ — 書き出し (`mokume render`) と ``SketchSettings/clock`` を
    /// ``SketchSettings/ClockMode/frames`` にした窓では、フレームの時計の秒から同じ式で巡る。
    /// `mokume render --seconds 4` で書き出すと、4 秒周期の枚は位相 0 から 1 の手前までを覆い、継ぎ目の
    /// ないループになる。時刻を指定した観測の枚では、``Sketch/draw()`` の中だけ観測の秒から巡る
    /// (``time`` と同じ)。
    ///
    /// **`period` が 0 以下・数でない値・無限のときは 0 を返す。** 周期が定まらず、毎フレーム呼ばれる口が
    /// 数でない値を返すと**絵が黙って消える**ためで ([ADR-0020] 決定 5)、注意は 1 度だけ言う。
    /// ``Sketch/setup()``・``Sketch/draw()``・入力のコールバックの外 (`init` や `Task` の中) から読んだときも、
    /// ``time`` と同じく 0 を返し、そのことを 1 度だけ知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    // shot: 撮れない 時計から周期の位相を読んで返す口で、撮影は 0 秒の 1 枚だけなので巡りが絵に出ない (位相は 0 のまま)
    public func phase(period: some ScalarConvertible) -> Float {
        guard let runtime = Self.liveRuntime(.read(returning: "0")) else { return 0 }
        return periodPhase(ofSeconds: runtime.timeSeconds, period: period.asFloat)
    }
}

/// `seconds` を `period` 秒で巻き戻した位置を、0 以上 1 未満で返す (``SketchPart/phase(period:)``)。
///
/// 余りは `Double` のまま取り、割った比だけを `Float` にする。**負の秒は 0 以上へ畳む** — 切り捨ての
/// 剰余は負に負を返すので、周期を足して戻す。足した結果が周期ちょうどに丸まる値と、比が `Float` で
/// 1 に丸まる値は、1 周ぶんずれて読まれないよう 0 を返す。周期が 0 以下・非有限なら 0 を返し、
/// 1 度だけ知らせる。
func periodPhase(ofSeconds seconds: Double, period: Float) -> Float {
    guard period.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.phase),
            "phase(): got a period that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    guard period > 0 else {
        NumberValues.warnOnce(
            .emptyRange(.phase), "phase(): the period is zero or negative, so 0 was returned")
        return 0
    }
    let length = Double(period)
    var remainder = seconds.truncatingRemainder(dividingBy: length)
    if remainder < 0 { remainder += length }
    let phase = Float(remainder / length)
    return phase < 1 ? phase : 0
}
