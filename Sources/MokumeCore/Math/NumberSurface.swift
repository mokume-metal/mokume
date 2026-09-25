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

        /// 注意を出した口。
        enum Entry: Hashable {
            case map
            case lerp
            case constrain
            case norm
            case smoothstep
        }
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }
}

// MARK: - 角度の単位を直す

/// 度をラジアンに直す。
///
/// ```swift
/// rotate(radians(45))
/// ```
///
/// **このパッケージが角度を受け取る口は、すべてラジアンで名乗っている**
/// (``Sketch/rotate(_:)`` の引数名が `radians`)。度で考えたい絵 — 円を 12 等分する、
/// 30 度ずつ回す — は、ここを通してから渡す。
///
/// **単位を切り替える状態は持たない。** `angleMode()` は無く、単位は呼んだ 1 行から
/// 読める ([ADR-0033] 決定 4 が `colorMode()` を持たないのと同じ理由)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

/// ラジアンを度に直す。``radians(_:)`` の逆。
///
/// ```swift
/// let tilt = degrees(atan2(mouseY - height / 2, mouseX - width / 2))
/// ```
///
/// 角度を**読みたい**ときのためにある — 画面に出す、度で書かれた表と突き合わせる、
/// といった用途である。描く口へ渡す値は直さなくてよい。
public func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

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
    _ value: Float, _ inLow: Float, _ inHigh: Float, _ outLow: Float, _ outHigh: Float
) -> Float {
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
public func lerp(_ start: Float, _ stop: Float, _ amount: Float) -> Float {
    guard start.isFinite, stop.isFinite, amount.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.lerp),
            "lerp(): got a value that is not a number, or an infinite one, so the start was returned"
        )
        return start.isFinite ? start : 0
    }
    return interpolate(start, stop, amount)
}

/// 間を取る計算。``lerp(_:_:_:)`` と ``map(_:_:_:_:_:)`` が共有する。端は有限であること。
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
private func interpolate(_ start: Float, _ stop: Float, _ amount: Float) -> Float {
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
public func constrain(_ value: Float, _ low: Float, _ high: Float) -> Float {
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
public func norm(_ value: Float, _ start: Float, _ stop: Float) -> Float {
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
public func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
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
