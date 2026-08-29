// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 差込口へ入るものを束ねる単位。
///
/// **持つのは登録の 1 メソッドだけで、束自身はフレームのイベントを受け取らない**
/// ([ADR-0024] 決定 3)。1 つのパッケージが複数の差込口へ入る (映像を送る出口と、
/// 受け取る入り口を同じパッケージが持つ) ため、束ねる単位は要る。
///
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
    private(set) var outlets: [any Outlet] = []
    private(set) var inlets: [any Inlet] = []

    init() {}

    /// 出口を足す。**足した順に呼ばれる。**
    public func add(outlet: any Outlet) { outlets.append(outlet) }

    /// 入り口を足す。**足した順に呼ばれる。**
    public func add(inlet: any Inlet) { inlets.append(inlet) }
}
