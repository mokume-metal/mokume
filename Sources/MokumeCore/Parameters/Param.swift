// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走らせたまま動かせる値として宣言する。
///
/// ```swift
/// final class MySketch: Sketch {
///     @Param(0...200) var radius: Double = 80
///     @Param(choices: ["circle", "square"]) var shape: String = "circle"
///
///     func draw() {
///         circle(width / 2, height / 2, Float(radius))
///     }
/// }
/// ```
///
/// 候補は **Swift の enum でも書ける** — String を生の値に持つ `CaseIterable` の enum を、型の側に
/// 何も書き足さずにそのまま宣言する。`switch` が網羅されるので、綴り間違いは組む時点で止まる:
///
/// ```swift
/// enum Palette: String, CaseIterable { case ember, tide, moss }
///
/// final class MySketch: Sketch {
///     @Param var palette: Palette = .ember
///
///     func draw() {
///         switch palette {
///         case .ember: background(40, 12, 8)
///         case .tide: background(8, 24, 40)
///         case .moss: background(16, 30, 12)
///         }
///     }
/// }
/// ```
///
/// 面に出る型は `string` のままで、候補は enum の `allCases` から作る。外から書く値も、保存から
/// 戻す値も、**候補の外 (enum に無い case の生の値) は文字の候補と同じ理由で断る**。保存した case を
/// 消す・名前を変えると、その保存は候補の外として捨てて名乗り、コードの既定値の case が効く。case を
/// 足しただけなら、保存した値はそのまま戻る。
///
/// 宣言した値は名前・型・範囲つきで面から見える。読み書きは普通のプロパティと
/// 変わらない — 書いた後に動かせるようになるだけである。例外は 1 つで、次の項にある。
///
/// - **値を書き換えるとき、非有限の数 (NaN・無限) は受け取らない** ([ADR-0030] 決定 3)。
///   `radius = .nan` と書いても値は前のまま動かず、標準エラーへ 1 度だけ知らせる
///   (`radius += .infinity` も同じ)。組と色は成分のどれか 1 つでも非有限なら、値ごと受け取らない。
///   載せたままにすると、保存もつまみの応答も他の値を含めて書けなくなるためである。**有限の値は
///   範囲の外でも素通し**する — 範囲は面のための宣言であって、値の不変条件ではない。
///   **生まれのときの値 (宣言の初期値と、`init` の中の代入) が非有限なら、型の零から始まる**
///   (`@Param var radius: Double = .nan` は `0`、組は `SIMD2(0, 0)`、色は 4 成分とも 0)。前の値が
///   無いので「保つ」が成り立たないためで、標準エラーへ 1 度だけ知らせる
///   ([#2394](https://github.com/mokume-metal/mokume/issues/2394))
/// - **範囲の端が非有限なら、範囲を書かなかったものとして扱う** (`@Param(0...Double.infinity)`)。
///   窓のつまみは出ず、外からの書き込みは範囲へ収めない。標準エラーへ 1 度だけ知らせる
///   ([#2475](https://github.com/mokume-metal/mokume/issues/2475))
/// - 名前は既定でプロパティの名前になる。`name:` を書けばそちらが勝つ
/// - **同じ名前を二度宣言するとビルドが失敗する** ([ADR-0030] 決定 5)。面から引ける
///   名前とコードに書いた名前が食い違う形を、実行してから気付く形にしない
/// - **型を書く。** `@Param var radius = 80.0` のように型を省いた形は展開できない
///   (置き場の型が決まらない)
/// - **範囲を書かなかった数値には、窓のつまみが出ない** ([ADR-0030] 決定 8)。値は
///   面に出るし外からは書ける。つまみが要るなら範囲を書く
/// - **実数のスライダーの刻みは `step:` で書く** (`@Param(0...1, step: 0.05)`)。刻みは窓の動き方
///   だけを決め、値は刻みへ丸めない。整数のスライダーは 1 刻みのまま
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), arbitrary)
public macro Param(name: String? = nil) =
    #externalMacro(module: "MokumeMacros", type: "ParamMacro")

/// 走らせたまま動かせる値として、動ける幅を添えて宣言する。
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), arbitrary)
public macro Param(_ range: ClosedRange<Double>, name: String? = nil) =
    #externalMacro(module: "MokumeMacros", type: "ParamMacro")

/// 走らせたまま動かせる値として、動ける幅と、スライダーの刻みを添えて宣言する。
///
/// ```swift
/// final class Dots: Sketch {
///     @Param(0...1, step: 0.05) var density: Double = 0.4
/// }
/// ```
///
/// 窓のスライダーが 0.05 ずつ動く (0.4 の次は 0.45)。**刻みはスライダーの動き方だけを決める** —
/// 外から書いた値 (`0.37`)・保存からの復元・コードからの代入は刻みへ丸めず、そのまま入る。
/// 範囲へ収めたことを名乗る `clamped` の意味も変わらない。**整数の範囲 (`0...10`) の刻みは 1 の
/// まま**で、`step:` は実数の範囲 (`float`・`vec2`・`vec3`) にだけ付く。
///
/// 刻みが 0 以下・非有限、または実数でない値 (整数・真偽・文字・色) に付けたときは、置かずに
/// (刻みの無いスライダーのまま) 1 度だけ標準エラーへ知らせる。
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), arbitrary)
public macro Param(_ range: ClosedRange<Double>, step: Double, name: String? = nil) =
    #externalMacro(module: "MokumeMacros", type: "ParamMacro")

/// 走らせたまま動かせる値として、動ける幅を添えて宣言する。
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), arbitrary)
public macro Param(_ range: ClosedRange<Int>, name: String? = nil) =
    #externalMacro(module: "MokumeMacros", type: "ParamMacro")

/// 走らせたまま動かせる値として、許した候補を添えて宣言する。
///
/// 候補が面に出れば、外の書き手は合法値を総当たりしない。
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), arbitrary)
public macro Param(choices: [String], name: String? = nil) =
    #externalMacro(module: "MokumeMacros", type: "ParamMacro")
