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
/// 宣言した値は名前・型・範囲つきで面から見える。読み書きは普通のプロパティと
/// 変わらない — 書いた後に動かせるようになるだけである。例外は 1 つで、次の項にある。
///
/// - **値を書き換えるとき、非有限の数 (NaN・無限) は受け取らない** ([ADR-0030] 決定 3)。
///   `radius = .nan` と書いても値は前のまま動かず、標準エラーへ 1 度だけ知らせる
///   (`radius += .infinity` も同じ)。組と色は成分のどれか 1 つでも非有限なら、値ごと受け取らない。
///   載せたままにすると、保存もつまみの応答も他の値を含めて書けなくなるためである。**有限の値は
///   範囲の外でも素通し**する — 範囲は面のための宣言であって、値の不変条件ではない。
///   **生まれのときの値 (宣言の初期値と、`init` の中の代入) は検めない** — 前の値が無いので
///   「保つ」が成り立たない ([#2394](https://github.com/mokume-metal/mokume/issues/2394))
/// - 名前は既定でプロパティの名前になる。`name:` を書けばそちらが勝つ
/// - **同じ名前を二度宣言するとビルドが失敗する** ([ADR-0030] 決定 5)。面から引ける
///   名前とコードに書いた名前が食い違う形を、実行してから気付く形にしない
/// - **型を書く。** `@Param var radius = 80.0` のように型を省いた形は展開できない
///   (置き場の型が決まらない)
/// - **範囲を書かなかった数値には、窓のつまみが出ない** ([ADR-0030] 決定 8)。値は
///   面に出るし外からは書ける。つまみが要るなら範囲を書く
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
