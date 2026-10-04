// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 形の組み立ての中で書いた乱数の種を、出口で戻す ([#1936])。
//
// 乱数の列 (``randomness``) はランタイムが持ち、``Canvas`` の出口 (``Canvas/Manner``) は写さない。
// 組み立てる側 (``Canvas/createShape(_:)``) が入口と出口を知らせ、書く側 (``writeSeed(_:)``) が
// 控えを通す。規則は ``SeedScopes`` が持つ。知らせる先 (``shapeAssemblyListener``) へは、
// ``runningSketch`` と同じ所 (``withActiveRuntime(_:)``) で自分を差す — 種を書く先と、出口で
// 戻す先が同じランタイムになる ([#2041])。
//
// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
// [#2041]: https://github.com/mokume-metal/mokume/issues/2041
extension SketchRuntime: ShapeAssemblyListener {
    func shapeAssemblyBegan() {
        seedScopes.enter()
    }

    func shapeAssemblyEnded() {
        seedScopes.exit(restoring: &randomness)
    }

    /// 乱数の種を書く (``Sketch/randomSeed(_:)``)。組み立ての中なら、出口で戻せるよう控える。
    func writeSeed(_ seed: Int) {
        seedScopes.write(seed: seed, over: &randomness)
    }
}
