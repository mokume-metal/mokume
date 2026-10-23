// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// MARK: - 値を写す口が言う注意

/// 数を写す口が 1 度だけ言う注意。
///
/// 描く口の注意は面が持つ (``Canvas/Warning``) が、``map(_:_:_:_:_:)`` のような値を
/// 写すだけの口には持ち主が無い。控えだけをここに置く形は ``ColorValues`` と同じで、
/// 鍵で数える仕組みそのものは ``WarningLog`` が持つ ([#833])。
///
/// [#833]: https://github.com/mokume-metal/mokume/issues/833
enum NumberValues {
    /// 1 度だけ言う注意の種類。**事情ごとに数える** — 1 つの鍵を共有すると、先に
    /// 鳴ったほうが後の事情を永久に黙らせる。
    enum Warning: Hashable {
        /// 写す元の幅が 0 だった。**口ごとに数える** ([#1283]) — ``map(_:_:_:_:_:)`` と
        /// ``norm(_:_:_:)`` が 1 つの鍵を共有すると、先に鳴ったほうが他方を永久に黙らせる。
        /// ``smoothstep(_:_:_:)`` の幅 0 は段という答えを持つので、ここへは来ない。
        ///
        /// [#1283]: https://github.com/mokume-metal/mokume/issues/1283
        case emptyRange(Entry)
        /// 数でない値・無限の値が渡された。**口ごとに数える** — 事情は同じでも、
        /// 出す文面が口ごとに違ううえ、綴りを 1 つにすると先に鳴った口が残りを
        /// 永久に黙らせる。連想値にしてあるのは、口が増えても鍵の共有が起こり
        /// ようがない形にするためで、綴りを並べる (`lerpNotANumber` …) と
        /// 足す人が使い回せてしまう。
        case notANumber(Entry)
        /// 負の割合・負の時間が渡された。**口ごとに数える** (理由は ``notANumber(_:)`` と同じ)。
        /// 目標へ寄る式は、負の割合や時間のまま通すと目標から**遠ざかる** (`1 - exp(+x)` は負) うえ、
        /// 毎フレーム重ねると指数で発散するので、動かさずに知らせる。
        case negativeRate(Entry)

        /// 注意を出した口。
        enum Entry: Hashable {
            case map
            case lerp
            case constrain
            case norm
            case smoothstep
            case damp
            case pingpong
            case lerpAngle
            case dist
            case mag
            case sq
            case fract
            case mod
            case bezierPoint
            case bezierTangent
            case phase
        }
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }
}

// MARK: - 円周率の定数

/// 円周率 (π)。180 度をラジアンで書いた値。
///
/// ```swift
/// rotate(PI / 4)
/// ```
///
/// **`PI`・`HALF_PI`・`QUARTER_PI`・`TWO_PI`・`TAU` は手本 (Processing・p5.js) の綴りのまま**
/// で、Swift の命名 (lowerCamelCase) からは外れる。関数の層は手本で書けることを優先する
/// ためで、理由は [ADR-0020] 決定 1 の 2026-10-14 改訂にある。`tau` と綴る案は、手本の綴りで
/// 探せず、AI が書く `TWO_PI` が赤いままになるので採らなかった。
///
/// **総称の受け口へそのまま渡せる。** 描く口と数の口は `some ScalarConvertible` で受けるので、
/// `.pi` だけでは `Float` と `Double` のどちらか決まらず、`rotate(.pi / 2)` は
/// `ambiguous use of 'pi'` で赤くなる ([ADR-0035] 決定 6-a)。これらの定数は具体の `Float`
/// なので、`rotate(HALF_PI)` も `map(i, 0, n, 0, TWO_PI)` も型を名乗らずに通る。
/// `Float.pi` も正しい綴りで、書き換えは要らない。
///
/// **遮れる。** 自分で `let PI = 3.14` と宣言すれば、その範囲では自分の宣言が勝つ。
///
/// 時計の文字盤。12 本の目盛りを ``TWO_PI`` の 12 等分に置き、針は ``HALF_PI`` だけ戻して
/// 12 時を上にする。
///
/// ```swift
/// func draw() {
///     background(245)
///     translate(width / 2, height / 2)
///     for i in 0..<12 {
///         let a = map(i, 0, 12, 0, TWO_PI)
///         line(cos(a) * 150, sin(a) * 150, cos(a) * 170, sin(a) * 170)
///     }
///     let hand = map(time.truncatingRemainder(dividingBy: 60), 0, 60, 0, TWO_PI) - HALF_PI
///     line(0, 0, cos(hand) * 140, sin(hand) * 140)
/// }
/// ```
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
public let PI: Float = .pi

/// 円周率の半分 (π/2)。90 度。
///
/// ```swift
/// rotate(HALF_PI)
/// ```
///
/// 角度 0 は右向きなので、12 時を上にしたいときの戻し量にもなる (``PI`` の作例)。
public let HALF_PI: Float = .pi / 2

/// 円周率の 4 分の 1 (π/4)。45 度。
///
/// ```swift
/// rotate(QUARTER_PI)
/// ```
public let QUARTER_PI: Float = .pi / 4

/// 円周率の 2 倍 (2π)。1 周。
///
/// ```swift
/// arc(0, 0, 100, 100, 0, TWO_PI)
/// ```
///
/// 範囲を 1 周へ写すときにも使う — `map(i, 0, n, 0, TWO_PI)`。``TAU`` と同じ値。
public let TWO_PI: Float = .pi * 2

/// 1 周 (2π)。``TWO_PI`` と同じ値。
///
/// ```swift
/// rotate(TAU / 8)
/// ```
///
/// Processing・p5.js が `TWO_PI` と並べて持つ別名。
public let TAU: Float = .pi * 2

// MARK: - 角度の単位を直す

/// 度をラジアンに直す。
///
/// ```swift
/// rotate(radians(45))
/// ```
///
/// **このパッケージが角度を受け取る口は、すべてラジアンで名乗っている**
/// (``SketchPart/rotate(_:)`` の引数名が `radians`)。度で考えたい絵 — 円を 12 等分する、
/// 30 度ずつ回す — は、ここを通してから渡す。
///
/// **単位を切り替える状態は持たない。** `angleMode()` は無く、単位は呼んだ 1 行から
/// 読める ([ADR-0033] 決定 4 が `colorMode()` を持たないのと同じ理由)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func radians(_ degrees: some ScalarConvertible) -> Float { degrees.asFloat * .pi / 180 }

/// ラジアンを度に直す。``radians(_:)`` の逆。
///
/// ```swift
/// let tilt = degrees(atan2(mouseY - height / 2, mouseX - width / 2))
/// ```
///
/// 角度を**読みたい**ときのためにある — 画面に出す、度で書かれた表と突き合わせる、
/// といった用途である。描く口へ渡す値は直さなくてよい。
public func degrees(_ radians: some ScalarConvertible) -> Float { radians.asFloat * 180 / .pi }

// MARK: - 値を別の範囲へ写す

/// ある範囲の値を、別の範囲の値へ写す。
///
/// ```swift
/// let pointCount = map(mouseX, 0, width, 6, 60)
/// ```
///
/// 引数は写す値・元の範囲の下端と上端・写した先の下端と上端の順 (手本と同じ並び)。
///
/// **元の範囲の端は、写した先の端へちょうど写る** — `inLow` を写せば `outLow` が、`inHigh`
/// を写せば `outHigh` が返る。元の範囲の中の値は、写した先の両端の間の有限の値になる。
/// どちらも、範囲の幅が `Float` で表せないほど広くても変わらない (`map(0.5, 0, 1, -3e38, 3e38)`
/// は 0 を返す)。
///
/// **範囲の外は丸めない。** 元の範囲を外れた値は、そのまま外へ伸びる — `map(2, 0, 1, 0, 10)`
/// は 20 を返す。締めたいときは呼ぶ側で締める。伸びた先が `Float` の範囲を越えたら ±∞ を
/// 返す (数でない値は返さない)。
///
/// **元の幅が 0 のとき、数でない値・無限の値が混じったときは、写した先の下端を返す。**
/// 手本は ±∞ や NaN を返すが、``Sketch/draw()`` から毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func map(
    _ value: some ScalarConvertible, _ inLow: some ScalarConvertible, _ inHigh: some ScalarConvertible,
    _ outLow: some ScalarConvertible, _ outHigh: some ScalarConvertible
) -> Float {
    let (value, inLow, inHigh) = (value.asFloat, inLow.asFloat, inHigh.asFloat)
    let (outLow, outHigh) = (outLow.asFloat, outHigh.asFloat)
    guard value.isFinite, inLow.isFinite, inHigh.isFinite, outLow.isFinite, outHigh.isFinite
    else {
        NumberValues.warnOnce(
            .notANumber(.map), "map(): got a value that is not a number, or an infinite one, so the low end of the destination was returned")
        return outLow.isFinite ? outLow : 0
    }
    guard inHigh != inLow else {
        NumberValues.warnOnce(
            .emptyRange(.map),
            "map(): the source range has zero width, so the low end of the destination was returned")
        return outLow
    }
    // 元の範囲のどこか (0…1 の外もありうる) を求め、間を取る計算へ渡す (#1476)
    return interpolate(outLow, outHigh, proportion(value, inLow, inHigh))
}

/// 値が範囲のどこにあるかの比 (0…1 の外もありうる)。``map(_:_:_:_:_:)``・``norm(_:_:_:)``・
/// ``smoothstep(_:_:_:)`` が共有する。**注意は言わない** — 中で他の口を呼ぶと、呼んだ先の名で
/// 注意が鳴る ([#1283])。値と端は有限で、幅は 0 でないこと。
///
/// 範囲の幅が有限なら `(value - low) / (high - low)` そのもので、断片 (MSL) の `smoothstep` が
/// 書く式と 1 字も違わない。**幅が `Float` で溢れる組だけ、端と値を半分にしてから比を取る**
/// ([#1476])。半分どうしの差は溢れず、端は大きいので半分にしても丸まらない — 値が端ちょうど
/// なら、比も 0 と 1 ちょうどになる。有限の値から数でない値は返らない (値が範囲から遠く
/// 外れて溢れれば ±∞)。
///
/// [#1283]: https://github.com/mokume-metal/mokume/issues/1283
/// [#1476]: https://github.com/mokume-metal/mokume/issues/1476
private func proportion(_ value: Float, _ low: Float, _ high: Float) -> Float {
    let span = high - low
    return span.isFinite
        ? (value - low) / span
        : (value / 2 - low / 2) / (high / 2 - low / 2)
}

// MARK: - 2 つの値の間を取る

/// 2 つの値の間を取る。
///
/// ```swift
/// let x = lerp(20, width - 20, 0.25)
/// ```
///
/// 引数は始まり・終わり・その間のどこか、の順 (手本と同じ並び)。`amount` が 0 なら
/// `start`、1 なら `stop` が**ちょうど**返る。
///
/// **端が有限で `amount` が 0…1 なら、返る値は有限で、端の間に収まる。** 端の差が `Float` で
/// 表せないほど離れていても変わらない (`lerp(-3e38, 3e38, 0.5)` は 0 を返す)。
///
/// **0…1 の外は締めない。** `lerp(0, 10, 2)` は 20 を、`lerp(0, 10, -1)` は -10 を返す
/// (手本と同じで、``map(_:_:_:_:_:)`` の外挿と揃う)。締めたいときは ``constrain(_:_:_:)``
/// を通す。伸びた先が `Float` の範囲を越えたら ±∞ を返す (数でない値は返さない) —
/// `lerp(1e38, 2e38, 10)` は ∞ になる。
///
/// **数でない値・無限の値が混じったときは `start` を返す。** 毎フレーム呼ばれる口が
/// 数でない値を返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func lerp(_ start: some ScalarConvertible, _ stop: some ScalarConvertible, _ amount: some ScalarConvertible) -> Float {
    let (start, stop, amount) = (start.asFloat, stop.asFloat, amount.asFloat)
    guard start.isFinite, stop.isFinite, amount.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.lerp),
            "lerp(): got a value that is not a number, or an infinite one, so the start was returned"
        )
        return start.isFinite ? start : 0
    }
    return interpolate(start, stop, amount)
}

/// 間を取る計算。``lerp(_:_:_:)`` と ``map(_:_:_:_:_:)`` が共有し、``lerpColor(_:_:_:)`` も
/// 成分ごとに通す (そのためモジュールの中へ開けてある)。端は有限であること。
/// `amount` は ±∞ でもよい — ``map(_:_:_:_:_:)`` の比は、写す値が元の範囲から遠く外れると
/// 溢れる。
///
/// **有限の幅は今までどおりの式で移し、`amount` が 1 のときだけ `stop` を返す** ([#1453])。
/// 幅 (`stop - start`) を丸めてから掛けるので、1 を掛けても `stop` に戻らないことがある
/// (`1e8 + (1 - 1e8) * 1` は 0)。**1 だけを差し替えても値は逆行しない** — 1 の直前を掛けると
/// 幅は半 ulp 以上縮み、1 の直後を掛けると 1 ulp 以上伸びる。幅の丸めは半 ulp までなので、
/// 1 の直前の値は `stop` を越えず、1 の直後の値は `stop` の手前に残らない。
///
/// **幅が `Float` で溢れる組だけ、両端から直に混ぜる。** `random(low, high)` が塞いだのと同じ
/// 穴で、流儀も同じである ([#1312])。幅が溢れるのは端が異符号のときだけなので、0…1 の間では
/// どちらの積も端より大きくならず、和は端の間に落ちる。0…1 の外では 2 つの積が同じ符号に
/// なるので、溢れても ±∞ で止まり、`∞ - ∞` の NaN は作らない。
///
/// **溢れない幅まで混ぜる形に替えない。** 端はちょうどになるが、`start == stop` で `start` に
/// 戻らない・`amount` を増やして値が逆行する・外挿で NaN を返す、の 3 つを壊すうえ、端の間の
/// ふつうの値も 4 つに 1 つが最下位ビットで動く。
///
/// [#1312]: https://github.com/mokume-metal/mokume/issues/1312
/// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
func interpolate(_ start: Float, _ stop: Float, _ amount: Float) -> Float {
    let span = stop - start
    guard span.isFinite else { return (1 - amount) * start + amount * stop }
    // 幅が無ければ、どこを取っても始まり。比が ∞ で来ても `0 × ∞` の NaN を作らない
    guard span != 0 else { return start }
    return amount == 1 ? stop : start + span * amount
}

// MARK: - 値を範囲へ締める

/// 値を、決めた範囲の中へ締める。
///
/// ```swift
/// let radius = constrain(mouseX / 4, 4, 120)
/// ```
///
/// 引数は締める値・下端・上端の順 (手本と同じ並び)。範囲の中の値はそのまま返る。
///
/// **上下が逆に渡されたら入れ替えて締める。** `constrain(5, 10, 0)` は `constrain(5, 0, 10)`
/// と同じ 5 を返す — 逆向きの範囲を受け取る ``map(_:_:_:_:_:)`` と揃う。
///
/// **数でない値・無限の値が混じったときは、範囲の端へ倒す** — 両端とも有限なら下端を、
/// 片側だけ有限ならその端を、どちらも数でなければ 0 を返す。毎フレーム呼ばれる口が
/// 数でない値を返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func constrain(_ value: some ScalarConvertible, _ low: some ScalarConvertible, _ high: some ScalarConvertible) -> Float {
    let (value, low, high) = (value.asFloat, low.asFloat, high.asFloat)
    guard value.isFinite, low.isFinite, high.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.constrain),
            "constrain(): got a value that is not a number, or an infinite one, so the low end of the range was returned"
        )
        // 両端のうち有限なほうへ倒す。どちらも数でなければ返す先が無いので 0 にする
        if low.isFinite && high.isFinite { return min(low, high) }
        if low.isFinite { return low }
        if high.isFinite { return high }
        return 0
    }
    return min(max(value, min(low, high)), max(low, high))
}

// MARK: - 範囲の中のどこかを 0…1 で表す

/// 値が範囲の中のどこにあるかを、始まりを 0・終わりを 1 とする割合で返す。
///
/// ```swift
/// let progress = norm(time, 2, 6)
/// ```
///
/// 引数は値・範囲の始まりと終わりの順 (手本と同じ並び)。写した先を 0…1 にした
/// ``map(_:_:_:_:_:)`` と同じ値を返す — `start` なら 0、`stop` なら 1 がちょうど返り、逆向きの
/// 範囲も受ける (`norm(20, 80, 0)` は 0.75)。
///
/// **範囲の外は締めない。** `norm(120, 0, 80)` は 1.5 を、`norm(-40, 0, 80)` は -0.5 を返す
/// (手本と同じ)。0…1 に収めたいときは ``constrain(_:_:_:)`` を通すか、窓・締め・曲線を 1 本で
/// 済ませる ``smoothstep(_:_:_:)`` を使う。
///
/// **範囲の幅が 0 のとき、数でない値・無限の値が混じったときは 0 を返す。** 手本は ±∞ や NaN を
/// 返すが、``Sketch/draw()`` から毎フレーム呼ばれる口が数でない値を返すと、**絵が黙って消える**
/// ([ADR-0020] 決定 5)。``map(_:_:_:_:_:)`` が写した先の下端を返すのと揃えてある。注意は 1 度だけ
/// 言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func norm(_ value: some ScalarConvertible, _ start: some ScalarConvertible, _ stop: some ScalarConvertible) -> Float {
    let (value, start, stop) = (value.asFloat, start.asFloat, stop.asFloat)
    guard value.isFinite, start.isFinite, stop.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.norm),
            "norm(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    guard stop != start else {
        NumberValues.warnOnce(
            .emptyRange(.norm), "norm(): the range has zero width, so 0 was returned")
        return 0
    }
    return proportion(value, start, stop)
}

// MARK: - 窓・締め・曲線を 1 本で

/// 窓の中で 0 から 1 へ、両端で速さが 0 になる曲線で移る。
///
/// ```swift
/// let fade = smoothstep(2.4, 5.4, time)
/// ```
///
/// **断片 (MSL) の `smoothstep` と同じ名前・同じ引数の並び・同じ式である。** 窓の中の割合を
/// 0…1 に締めて `t` とし、`t * t * (3 - 2 * t)` を返す。シェーダに書いた式を、そのまま Swift の
/// 側へ写せる。
///
/// - **窓の外は締める。** 縁を含めて `edge0` の側の外では 0、`edge1` の側の外では 1 を返す —
///   `smoothstep(2, 6, 1)` は 0、`smoothstep(2, 6, 9)` は 1
/// - **逆向きの窓 (`edge0 > edge1`) は入れ替えず、下り坂になる。** `smoothstep(6, 2, 3)` は
///   `1 - smoothstep(2, 6, 3)` と同じ 0.84375。断片の式も場合分けせずに同じ値を出す
/// - **幅 0 の窓 (`edge0 == edge1`) は段になる** — `x` が縁より下なら 0、縁から上は 1 (断片の
///   `step(edge, x)` と同じ)。注意は言わない。縁の外では断片の式と同じ値で、縁ちょうどは断片の
///   式では決まらない (0 ÷ 0)。締める口には段という答えがあるので、幅 0 で 0 を返して注意を
///   言う ``norm(_:_:_:)`` / ``map(_:_:_:_:_:)`` とはここが違う
///
/// **数でない値・無限の値が混じったときは 0 を返す。** 毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。**ここだけは断片の
/// `smoothstep` と値が違いうる** — 断片が無限や数でない値に何を返すかには揃えない。幅が `Float`
/// で溢れる窓 (`smoothstep(-3e38, 3e38, 0)`) も、ここは窓の中の割合どおりの値 (0.5) を返す。
/// 同じ名前でも、画素まで揃えることは約束しない ([ADR-0020] 決定 1 の 2026-09-09 改訂)。
///
/// 曲線を通さずに、窓の中の割合だけが欲しいなら ``norm(_:_:_:)`` を使う (こちらは締めない)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func smoothstep(_ edge0: some ScalarConvertible, _ edge1: some ScalarConvertible, _ x: some ScalarConvertible) -> Float {
    let (edge0, edge1, x) = (edge0.asFloat, edge1.asFloat, x.asFloat)
    guard edge0.isFinite, edge1.isFinite, x.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.smoothstep),
            "smoothstep(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    // 幅 0 の窓は段 (#1283 の判断 A)。断片の `step(edge, x)` と同じく、縁ちょうどから 1
    guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
    // 締めは `constrain` を呼ばずに書く — 呼ぶと、そちらの名で注意が鳴りうる
    let t = min(max(proportion(x, edge0, edge1), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - 目標へ寄る・往復する・角を混ぜる

/// 目標へ、フレームの長さに依らない硬さで寄る。
///
/// <!-- example: 文脈 var eyeX: Float = 200 -->
/// ```swift
/// eyeX = damp(eyeX, mouseX, 6, deltaTime)
/// ```
///
/// 引数は今の値・目標・硬さ (`lambda`、大きいほど速く寄る・1 秒あたり)・経った秒の順
/// (three.js の `MathUtils.damp` と同じ並び)。``lerp(_:_:_:)`` に `1 - exp(-lambda * dt)` を渡す
/// のと同じである。
///
/// **目標が一定なら、刻み方に依らず同じ軌跡になる。** `damp(0, 10, 4, 1)` を 1 回呼んだ値と、
/// `dt = 1/60` で 60 回重ねた値は同じになる。`x += (target - x) * 0.1` と書くと、1 枚ごとの率なので
/// フレームが落ちると追従が遅れ、`frameRate` を変えると硬さも変わる。
///
/// マウスを追う目。`frameRate` を 30 にしても 60 にしても、`mokume render` で書き出しても、
/// 同じ硬さで追う。瞳は ``lerpAngle(_:_:_:)`` で最短の向きへ回り、まぶたは ``pingpong(_:_:)`` で 2 秒で
/// 往復する。
///
/// ```swift
/// var eyeX: Float = 200
/// var eyeY: Float = 150
/// var look: Float = 0
///
/// func draw() {
///     background(240)
///     eyeX = damp(eyeX, mouseX, 6, deltaTime)
///     eyeY = damp(eyeY, mouseY, 6, deltaTime)
///     look = lerpAngle(look, atan2(mouseY - eyeY, mouseX - eyeX), 0.2)
///     let lid = pingpong(time, 1)          // 0 → 1 → 0 を 2 秒で
///     ellipse(eyeX, eyeY, 120, 120 * (0.3 + 0.7 * lid))
///     circle(eyeX + cos(look) * 30, eyeY + sin(look) * 30, 30)
/// }
/// ```
///
/// **`deltaTime` を渡すと、積分で作った状態になる。** 実時計で動く窓では、フレームの長さが
/// 実行ごとに違うので、同じ時刻の絵が実行ごとに揃わない ([ADR-0025] 決定 6 の「揃わない」側)。
/// フレームの時計 (`mokume render`・設定の `clock: .frames`) では、`deltaTime` が毎回同じなので
/// 揃う。時刻から絵が決まる作りにしたいなら、``damp(_:_:_:_:)`` ではなく ``smoothstep(_:_:_:)`` などで
/// `time` から直に値を出す。
///
/// **名前と並びは three.js に倣った** (手本 Processing・p5 に無い口。[ADR-0020] 決定 1)。
///
/// **負の `lambda`・負の `dt` は、動かさずに今の値を返す。** 式のまま通すと目標から遠ざかり、
/// 毎フレーム重ねると指数で発散して、絵が黙って消える。`dt` が 0 なら動かない (今の値が
/// そのまま返る)。0 は負ではないので知らせない。注意は 1 度だけ言う。
///
/// **数でない値・無限の値が混じったときは、今の値を返す** (今の値が有限でなければ 0)。
/// ``lerp(_:_:_:)`` が始まりを返すのと揃えてある。注意は 1 度だけ言う
/// ([ADR-0020] 決定 5)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
public func damp(
    _ current: some ScalarConvertible, _ target: some ScalarConvertible, _ lambda: some ScalarConvertible,
    _ dt: some ScalarConvertible
) -> Float {
    let (current, target, lambda, dt) = (current.asFloat, target.asFloat, lambda.asFloat, dt.asFloat)
    guard current.isFinite, target.isFinite, lambda.isFinite, dt.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.damp),
            "damp(): got a value that is not a number, or an infinite one, so the current value was returned")
        return current.isFinite ? current : 0
    }
    guard lambda >= 0, dt >= 0 else {
        NumberValues.warnOnce(
            .negativeRate(.damp),
            "damp(): lambda or dt is negative, so the current value was returned instead of moving away from the target")
        return current
    }
    // 掛けた積が溢れて ∞ になっても、exp(-∞) は 0 で割合は 1 (目標へちょうど着く)
    let amount = 1 - RuntimeMath.exp(-lambda * dt)
    return interpolate(current, target, amount)
}

/// 0 から `length` まで上がって 0 へ戻る、三角の波。
///
/// ```swift
/// let lid = pingpong(time, 1)   // 0 → 1 → 0 を 2 秒で
/// ```
///
/// 引数は時刻 (どんな値でもよい)・折り返す長さの順 (three.js の `MathUtils.pingpong` と同じ並び)。
/// 周期は `length` の 2 倍で、`pingpong(2.5, 2)` は 1.5、`pingpong(-0.5, 2)` は 0.5 を返す。
///
/// **負の `t` でも巡る。** `jumpTime` で時刻を戻しても、`abs(...)` と剰余で手書きした三角波のように
/// 崩れない。返る値は 0 以上 `length` 以下である。
///
/// **`length` が負なら、0 から負の側へ往復する** — 返る値は `length` 以上 0 以下になる。
///
/// **`length` が 0 のとき、数でない値・無限の値が混じったときは 0 を返す。** 幅の無い往復は
/// 定まらず、毎フレーム呼ばれる口が数でない値を返すと**絵が黙って消える**
/// ([ADR-0020] 決定 5)。``map(_:_:_:_:_:)`` の幅 0 と同じく、注意は 1 度だけ言う。
///
/// **名前と並びは three.js に倣った** (手本 Processing・p5 に無い口。[ADR-0020] 決定 1)。
/// 時刻を 0 以上 1 未満へ巡らせる口は別にある。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func pingpong(_ t: some ScalarConvertible, _ length: some ScalarConvertible) -> Float {
    let (t, length) = (t.asFloat, length.asFloat)
    guard t.isFinite, length.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.pingpong),
            "pingpong(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    guard length != 0 else {
        NumberValues.warnOnce(
            .emptyRange(.pingpong), "pingpong(): the length is zero, so 0 was returned")
        return 0
    }
    // 負の長さは、正の長さの往復を負の側へ写す
    let reach = abs(length)
    // 周期 2 * reach の中の位置 (0 以上 2 * reach 未満)。``mod(_:_:)`` と同じ畳み方
    let position = foldedIntoPeriod(t, by: 2 * reach)
    let rising = reach - abs(position - reach)
    return length < 0 ? -rising : rising
}

/// 最短の弧で、角を混ぜる (ラジアン)。
///
/// <!-- example: 文脈 var look: Float = 0 -->
/// <!-- example: 文脈 var eyeX: Float = 200 -->
/// <!-- example: 文脈 var eyeY: Float = 150 -->
/// ```swift
/// look = lerpAngle(look, atan2(mouseY - eyeY, mouseX - eyeX), 0.2)
/// ```
///
/// 引数は始まり・終わり・その間のどこか、の順 (``lerp(_:_:_:)`` と同じ並び)。
/// ``lerp(_:_:_:)`` で角を混ぜると、±π をまたぐところで 1 周回ってしまう —
/// `lerp(3, -3, 0.5)` は 0 を返すが、`lerpAngle(3, -3, 0.5)` は ±π の近く (約 3.14) を返す。
///
/// **`amount` が 0 なら `start` が、1 なら `stop` と同じ向きがちょうど返る。** 返す値は
/// `start` から短いほうへ進めた値で、**±π に畳まない** (`lerpAngle(3, -3, 1)` は -3 ではなく
/// -3 + 2π を返す)。同じ向きなので描く口へそのまま渡せ、`atan2` の返す ±π の外へ
/// 出ても、次のフレームの `start` にしてよい。2 つの向きがちょうど反対 (差が π) のときは、
/// `stop - start` の符号の側へ回る。
///
/// **0…1 の外は締めない。** `amount` が 1 を越えれば、同じ向きへ回り続ける (``lerp(_:_:_:)`` の
/// 外挿と同じ)。
///
/// **数でない値・無限の値が混じったときは `start` を返す** (`start` が有限でなければ 0)。
/// ``lerp(_:_:_:)`` と同じく、注意は 1 度だけ言う ([ADR-0020] 決定 5)。
///
/// **名前と並びは Unity・Godot に倣った** (手本 Processing・p5 に無い口。[ADR-0020] 決定 1)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func lerpAngle(_ start: some ScalarConvertible, _ stop: some ScalarConvertible, _ amount: some ScalarConvertible) -> Float {
    let (start, stop, amount) = (start.asFloat, stop.asFloat, amount.asFloat)
    guard start.isFinite, stop.isFinite, amount.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.lerpAngle),
            "lerpAngle(): got a value that is not a number, or an infinite one, so the start was returned")
        return start.isFinite ? start : 0
    }
    // 差を -π…π へ畳む。差が溢れて ∞ になった組は、畳めないので始まりを返す
    let turn = 2 * Float.pi
    var delta = (stop - start).truncatingRemainder(dividingBy: turn)
    guard delta.isFinite else { return start }
    if delta > .pi { delta -= turn } else if delta < -.pi { delta += turn }
    return interpolate(start, start + delta, amount)
}

// MARK: - 2 点の距離・二乗

/// 2 点の間の距離。
///
/// ```swift
/// let reach = dist(mouseX, mouseY, width / 2, height / 2)
/// ```
///
/// 引数は 1 つ目の点の x・y、2 つ目の点の x・y の順 (手本と同じ並び)。広がる波の格子 —
/// 中心からの距離で明るさを決め、波は 3 秒で一巡する。
///
/// ```swift
/// func draw() {
///     background(0)
///     noStroke()
///     for y in stride(from: Float(0), to: height, by: 20) {
///         for x in stride(from: Float(0), to: width, by: 20) {
///             let d = dist(x, y, width / 2, height / 2)
///             let wave = fract(d / 120 - mod(time, 3) / 3)
///             fill(255 * pow(wave, 3))
///             circle(x, y, 8)
///         }
///     }
/// }
/// ```
///
/// **これは関数の層の口で、手本の名前のまま** (ADR-0020 決定 1)。値型 `Vector2` の側は
/// `length` と名乗る — 関数の ``dist(_:_:_:_:)`` と `Vector2` の長さが並ぶのは、`circle()` と
/// `Circle` の使い分けと同じである。平面の 2 点だけで、3 次元の形は無い。
///
/// **2 乗が `Float` で溢れる距離でも、距離は有限で返る** (`dist(0, 0, 3e19, 4e19)` は 5e19)。
/// 結果そのものが `Float` の範囲を越えるときだけ ∞ を返す (数でない値は返さない)。
///
/// **数でない値・無限の値が混じったときは 0 を返す。** 毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func dist(
    _ x1: some ScalarConvertible, _ y1: some ScalarConvertible, _ x2: some ScalarConvertible, _ y2: some ScalarConvertible
) -> Float {
    let (x1, y1, x2, y2) = (x1.asFloat, y1.asFloat, x2.asFloat, y2.asFloat)
    guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.dist),
            "dist(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    return euclideanLength(x2 - x1, y2 - y1)
}

/// 原点からの距離。``dist(_:_:_:_:)`` の 1 つ目の点を原点 (0, 0) にしたもの。
///
/// ```swift
/// let speed = mag(mouseX - pmouseX, mouseY - pmouseY)
/// ```
///
/// `mag(3, 4)` は 5 を返す。**これは関数の層の口で、手本の名前のまま** (ADR-0020 決定 1)。
/// 値型 `Vector2` の側は `length` と名乗る。平面の 2 成分だけで、3 次元の形は無い。
///
/// **2 乗が `Float` で溢れても距離は有限で返り、数でない値・無限の値が混じったときは 0 を
/// 返す** (``dist(_:_:_:_:)`` と同じ)。注意は 1 度だけ言う。
public func mag(_ x: some ScalarConvertible, _ y: some ScalarConvertible) -> Float {
    let (x, y) = (x.asFloat, y.asFloat)
    guard x.isFinite, y.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.mag),
            "mag(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    return euclideanLength(x, y)
}

/// ベクトル (`dx`, `dy`) の長さ。``dist(_:_:_:_:)`` と ``mag(_:_:)`` が共有する。**注意は言わない** —
/// 値は数であること (差が溢れて ±∞ になったものは来てよい)。
///
/// **長さを開く規則は、値型 `Vector2` の `length` と同じ 1 本** (#2935)。2 乗の和が `2^-100` 以上
/// `2^100` 未満ならそのまま開くので、`3, 4` から 5 がちょうど返る。外 (2 乗が溢れる大きい値・
/// 0 や非正規数に潰れる小さい値) は、2 の冪で寄せて測るので、有限の距離は有限で返り、**0 になるのは
/// 0 ベクトルだけ**。結果が `Float` の範囲を越えるなら ∞ になる (差が溢れて ∞ になった入力も ∞)。
private func euclideanLength(_ dx: Float, _ dy: Float) -> Float {
    Vector2.measuredLength(of: SIMD2(dx, dy))
}

/// 2 乗。
///
/// ```swift
/// let radius: Float = 40
/// let area = sq(radius) * Float.pi
/// ```
///
/// `sq(-3)` は 9 を返す。**これは関数の層の口で、手本の名前のまま** (ADR-0020 決定 1)。
/// 結果が `Float` の範囲を越えたら ∞ を返す (``map(_:_:_:_:_:)`` の外挿と同じ。数でない値は
/// 返さない)。
///
/// **数でない値・無限の値が渡されたときは 0 を返す。** 毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func sq(_ value: some ScalarConvertible) -> Float {
    let value = value.asFloat
    guard value.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.sq),
            "sq(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    return value * value
}

// MARK: - 端数・剰余

/// 小数部分。整数部分を引いた残りを、0 以上 1 未満で返す。
///
/// ```swift
/// let phase = fract(time / 3)
/// ```
///
/// **負の値も 0 以上に畳む** — `fract(-0.25)` は 0.75 (整数部分は床で、0 へ向けた切り捨て
/// ではない)。断片 (GLSL・MSL) の `fract` と同じ名前・同じ定義で、シェーダに書いた式を
/// そのまま写せる。周期の位相を出すときに、負の時刻でも巡る。
///
/// **返る値は 1 にならない。** 絶対値が 3e-8 ほどより小さい負の値は、`1 + x` が `Float` で 1 に
/// 丸まる。1 周ぶんずれた 1 が返らないよう、その値は 0 へ畳む (周期の上では 0 と 1 は同じ
/// 位相で、0 のほうが元の値に近い)。``mod(_:_:)`` と同じ畳み方である。
///
/// **数でない値・無限の値が渡されたときは 0 を返す。** 毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func fract(_ value: some ScalarConvertible) -> Float {
    let value = value.asFloat
    guard value.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.fract),
            "fract(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    return foldedIntoPeriod(value, by: 1)
}

/// 剰余。`value` を `divisor` で割った余りを、`0` 以上 `divisor` 未満で返す。
///
/// ```swift
/// let cycle = mod(time, 12)       // 0 以上 12 未満を巡る
/// let hue = mod(time * 90 - 30, 360)  // 負の角度も 0…360 へ畳む
/// ```
///
/// `mod(7, 4)` は 3、`mod(-1, 4)` も 3 を返す。**負の値も 0 以上に畳む** — 手本の `%` は負の数
/// に負を返すので、巡る値を書くたびに足して引き直す書き方になっていた (小数にも使える)。
/// 断片 (GLSL) の `mod` と同じ定義である (MSL の `fmod` は C と同じく負を返す)。手本に名前の
/// 無い口で、断片と同じ綴りを採った。
///
/// **返る値は `divisor` にならない。** 絶対値が小さい負の値に `divisor` を足すと、`Float` では
/// `divisor` ちょうどに丸まる — `mod(-1e-6, 360)` がその例で、360 を返すと 1 周ぶんずれて読まれる。
/// そうなる値は 0 へ畳む (色相の巻き戻しが #1533 で踏んだ境界と同じ手当て)。
///
/// **`divisor` が負なら、符号が `divisor` に従う** — 結果は `divisor` より大きく 0 以下になる
/// (`mod(1, -4)` は -3)。
///
/// **`divisor` が 0 のとき、数でない値・無限の値が混じったときは 0 を返す。** 0 で割った余りは
/// 定まらず、手本は NaN を返すが、毎フレーム呼ばれる口が数でない値を返すと、**絵が黙って消える**
/// ([ADR-0020] 決定 5)。``map(_:_:_:_:_:)`` の幅 0 と同じく、注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func mod(_ value: some ScalarConvertible, _ divisor: some ScalarConvertible) -> Float {
    let (value, divisor) = (value.asFloat, divisor.asFloat)
    guard value.isFinite, divisor.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.mod),
            "mod(): got a value that is not a number, or an infinite one, so 0 was returned")
        return 0
    }
    guard divisor != 0 else {
        NumberValues.warnOnce(
            .emptyRange(.mod), "mod(): the divisor is zero, so 0 was returned")
        return 0
    }
    return foldedIntoPeriod(value, by: divisor)
}

/// `value` を `divisor` の周期へ巻き戻す。``fract(_:)`` と ``mod(_:_:)`` が共有する。**注意は
/// 言わない** — 値は有限で、`divisor` は 0 でなく有限であること。
///
/// **切り捨ての剰余は使わない。** `truncatingRemainder` は負の入力に負を返すので、符号が
/// `divisor` と食い違うときだけ `divisor` を足す。余りそのものは正確 (丸めない)。足した結果が
/// `divisor` ちょうどに丸まったら 0 へ畳む — 半開区間を外れた値を返さない。
/// `HueSaturationBrightness.wrapped` が #1533 で踏んだ境界と同じである。
func foldedIntoPeriod(_ value: Float, by divisor: Float) -> Float {
    let remainder = value.truncatingRemainder(dividingBy: divisor)
    // 余りが 0 なら符号の食い違いは起きない (-0 を返さないよう、0 は 0 で返す)
    guard remainder != 0 else { return 0 }
    let folded = (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    return abs(folded) < abs(divisor) ? folded : 0
}
