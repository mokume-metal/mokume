// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 形の組み立て (``Canvas/createShape(_:)``) の入口と出口を、``Canvas`` の外で状態を持つ側へ知らせる口
/// ([#1936])。
///
/// 組み立ての出口が戻す状態は ``Canvas/Manner`` が持つが、それが写すのは ``Canvas`` の格納と
/// ``Canvas/Style`` だけである。**組み立ての中で書けて形に焼き付く状態のうち、``Canvas`` の外に
/// あるものが 1 つある** — 乱数の列 (``Sketch/randomSeed(_:)``) で、持ち主はランタイム
/// (``SketchRuntime``) である。``Canvas`` はランタイムを参照しない (描画の層がスケッチの層を知らない
/// 向きを保つ) ので、知らせる口を ``Canvas`` の側に置き、ランタイムが受ける。
///
/// **入口の数だけ口を置かない。** 組み立ての入口は ``Sketch/createShape(_:)`` と、描き場所
/// (``Canvas/createGraphics(_:_:)``) の ``Canvas/createShape(_:)`` の 2 つで、後者はランタイムを
/// 経ない。どちらも最後は ``Canvas/createShape(_:)`` を通るので、通知はそこ 1 か所で出す。描き場所は
/// 作った面の通知先を引き継ぐ (``Canvas/shapeListener``)。
///
/// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
@MainActor
protocol ShapeAssemblyListener: AnyObject {
    /// 形の組み立てに入る。入れ子なら、内側の入口でも呼ばれる。
    func shapeAssemblyBegan()
    /// 形の組み立てを抜ける。**入口と必ず対で呼ばれる** — 空の形を返す早い抜け方
    /// (組み立ての中で描き切ったとき・#1588) でも。
    func shapeAssemblyEnded()
}
