// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 差込口へ入るものを束ねる単位。
///
/// **持つのは登録の 1 メソッドだけで、束自身はフレームのイベントを受け取らない**
/// ([ADR-0024] 決定 3)。1 つのパッケージが複数の差込口へ入る (映像を送る出口と、
/// 受け取る入り口を同じパッケージが持つ) ため、束ねる単位は要る。
///
/// <!-- example: 文脈 final class MySender: Outlet { func receive(_ frame: OutputFrame) {} } -->
/// <!-- example: 文脈 final class MyReceiver: Inlet { func supply() {} } -->
/// ```swift
/// struct MyPlugin: Plugin {
///     func register(into registry: PluginRegistry) {
///         registry.add(outlet: MySender())
///         registry.add(inlet: MyReceiver())
///     }
/// }
/// ```
///
/// ## 書いてあれば効き、書いていなければ効かない
///
/// 登録は明示だけで、実行時に探して読み込む形も、読み込んだだけで勝手に登録される
/// 形も採らない ([ADR-0024] 決定 5)。並びは ``Sketch/plugins`` 1 本で、**順序は
/// 宣言順**である (同 決定 4)。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol Plugin {
    /// 差込口へ登録する。**組み立てのときに 1 度だけ呼ばれる。**
    func register(into registry: PluginRegistry)
}

/// 束が差込口へ登録する先。
///
/// **仕分けは内部で行う** ([ADR-0024] 決定 4)。利用者から見た並びは 1 本で、
/// 出口だけを足す束も入り口だけを足す束も同じ並びに置ける。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public final class PluginRegistry {
    /// 登録された出口。**足した順に並ぶ。**
    public private(set) var outlets: [any Outlet] = []

    /// 登録された入り口。**足した順に並ぶ。**
    public private(set) var inlets: [any Inlet] = []

    /// 束の登録を検査するために、外から 1 つ作る。
    ///
    /// **開けてあるのは検査のためである** ([#605](https://github.com/mokume-metal/mokume/issues/605))。
    /// 決定 3 が束の面を登録の 1 メソッドだけに絞った結果、**そのメソッドだけが外から
    /// 検査できない**状態になっていた — 束を渡す先が作れず、何が登録されたかも読めない。
    /// 走らせて確かめる道は組み立ての土台 (`SketchRuntime`) 越しにしか無く、それは GPU を
    /// 要求するので、束の形を見るだけの検査が GPU の無い実行環境で丸ごと飛ぶ。
    ///
    /// 組み立ての中でこれを作るのは土台の仕事で、**スケッチを書く人が呼ぶものではない**。
    ///
    /// <!-- example: 文脈 final class MySender: Outlet { func receive(_ frame: OutputFrame) {} } -->
    /// <!-- example: 文脈 final class MyReceiver: Inlet { func supply() {} } -->
    /// <!-- example: 文脈 struct MyPlugin: Plugin { func register(into registry: PluginRegistry) { registry.add(outlet: MySender()); registry.add(inlet: MyReceiver()) } } -->
    /// ```swift
    /// let registry = PluginRegistry()
    /// MyPlugin().register(into: registry)
    /// // registry.outlets.count == 1 / registry.inlets.count == 1
    /// ```
    public init() {}

    /// 出口を足す。**足した順に呼ばれる。**
    public func add(outlet: any Outlet) { outlets.append(outlet) }

    /// 入り口を足す。**足した順に呼ばれる。**
    public func add(inlet: any Inlet) { inlets.append(inlet) }
}
