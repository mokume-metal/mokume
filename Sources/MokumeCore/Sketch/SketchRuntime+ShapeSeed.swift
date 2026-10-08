// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 形の組み立ての中で書いた乱数の種と揺らぎの設定を、出口で戻す ([#1936]・[#2041])。
//
// 乱数の列 (``randomness``) はランタイムが持ち、``Canvas`` の出口 (``Canvas/Manner``) は写さない。
// 揺らぎの設定はスケッチの口 (``Sketch/noiseSeed(_:)``) が本体の面 (``canvas``) の置き場へ書くが、
// ``Canvas/Manner`` が戻すのは組み立てている面の置き場で、直に作った面では別物である。どちらも
// 書く先はランタイムが決めるので、戻すのもランタイムが受ける。
//
// 組み立てる側 (``Canvas/createShape(_:)``) が入口と出口を知らせ、書く側 (``writeSeed(_:)``) が
// 控えを通す。規則は ``SeedScopes`` が持つ。知らせる先 (``shapeAssemblyListener``) へは、
// ``runningSketch`` と同じ所 (``withActiveRuntime(_:)``) で自分を差す — 種を書く先と、出口で
// 戻す先が同じランタイムになる ([#2041])。
//
// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
// [#2041]: https://github.com/mokume-metal/mokume/issues/2041
extension SketchRuntime: ShapeAssemblyListener {
    func shapeAssemblyBegan() {
        seedScopes.enter(noise: canvas.noiseSettings)
    }

    func shapeAssemblyEnded() {
        guard let noise = seedScopes.exit(restoring: &randomness) else { return }
        // **書き換えは ``Canvas/changeNoise(_:)`` を通す** — 中の設定で図形を置いた面があれば、
        // 戻す前にその開いた列を閉じさせる (置いた時点の種で引く・#1503。描き切らない・#1855)。
        // 組み立てている面が本体と置き場を共有していれば、面の出口が先に同じ値へ戻しているので、
        // ここは同じ値の書き直しで何もしない
        canvas.changeNoise { $0 = noise }
    }

    /// 乱数の種を書く (``Sketch/randomSeed(_:)``)。組み立ての中なら、出口で戻せるよう控える。
    func writeSeed(_ seed: Int) {
        seedScopes.write(seed: seed, over: &randomness)
    }
}
