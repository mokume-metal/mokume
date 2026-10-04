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
/// **入口の数だけ口を置かない。** 組み立ての入口は ``Sketch/createShape(_:)`` と、``Canvas`` の
/// ``Canvas/createShape(_:)`` の 2 つで、後者はランタイムを経ない。どちらも最後は
/// ``Canvas/createShape(_:)`` を通るので、通知はそこ 1 か所で出す。知らせる先は面ごとに持たず、
/// ``shapeAssemblyListener`` の 1 口から引く (下の「知らせる先は面に付けない」)。
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

/// いま形の組み立てを知らせる先 ([#2041])。
///
/// **知らせる先は面に付けない。** 乱数の種を書く口 (``Sketch/randomSeed(_:)``) が書くのは、面の
/// 列ではなく**いま走っているランタイム** (`runningSketch`) の列である。知らせる先を面ごとに持つと
/// 鍵が 2 つになり、ランタイムが付けた面 (本体の面と、そこから作った描き場所) でしか戻らなかった —
/// 公開の init で直に作った面 (``Canvas/init(target:gpu:)``) とそこから作った描き場所は、走っている
/// スケッチの中で使えば列があるのに、知らせる先を持たず、中で書いた種が外へ漏れていた ([#2041])。
/// そこで書く鍵と同じ寿命の 1 口に揃える。差して外すのは、ランタイムが `runningSketch` を差す所
/// (`SketchRuntime.withActiveRuntime(_:)`) だけである。`runningSketch` を差すのもそこだけで、検査が
/// ランタイムを差すときも同じ口を通す — `runningSketch` だけを手で差すと、こちらが差さらない。
///
/// 揺らぎの種と細かさも同じ相手が戻す。スケッチの口 (``Sketch/noiseSeed(_:)``) が書くのは本体の面の
/// 置き場で、組み立てている面の出口 (``Canvas/Manner``) が戻すのは組み立てている面の置き場だから
/// である (直に作った面では別物・``SeedScopes``)。
///
/// ``Canvas`` が知るのはこのプロトコルだけで、スケッチの層 (`runningSketch`) は読まない。ランタイムの
/// 外で直に回す面では `nil` のままで、組み立ては今までどおり動く — そこには乱数の列も無い。
///
/// ADR-0010 決定 2 のとおり、main actor に隔離した明示のグローバルとして置く。
///
/// [#2041]: https://github.com/mokume-metal/mokume/issues/2041
@MainActor
var shapeAssemblyListener: (any ShapeAssemblyListener)?
