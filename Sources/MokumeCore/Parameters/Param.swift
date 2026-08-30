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
/// 変わらない — 書いた後に動かせるようになるだけである。
///
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
