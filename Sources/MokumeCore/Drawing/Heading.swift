// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 粒がどちらへ飛ぶか。
///
/// 使い方は ``Sketch/emit(_:from:toward:rate:speed:life:size:color:)`` にある。
///
/// **飛ぶ向きだけを決める。** どこから出るかは ``Emitter`` が決めるので、向きを差し替えても
/// 出る場所は変わらない (``Emitter`` と対になる)。速さも別で、`emit` の `speed` の幅から引く —
/// 粒の初速は「ここで引いた長さ 1 の向き × 引いた速さ」である。
///
/// 向きは出た場所と無関係に引く。半径のある ``Emitter/sphere(_:_:_:radius:)`` から `.sphere` で
/// 撒いても、粒が球の外向きへ飛ぶとは限らない。中心から吹き出す形にするなら、1 点
/// (``Emitter/point(_:_:_:)``) から `.sphere` で撒く。
public enum Heading: Equatable, Sendable {
    /// 画面の面内 (x と y の面) で、`angle` の幅から一様に引いた角度 (ラジアン) へ。
    ///
    /// 0 が +x (右)、π/2 が +y (下)。**奥行き (z) の成分は常に 0** なので、視点を回して
    /// 横から見ると、粒は出た場所を通る 1 枚の面の上を飛ぶ。奥行きへ散らすなら `.sphere` を使う。
    ///
    /// 幅を 1 つに決めたいときは `.plane(0...0)` のように書く。
    case plane(_ angle: ClosedRange<Float>)
    /// 全方位へ (球面上のどの向きも同じ確からしさで)。
    case sphere

    /// 数の成分。**受け口が、数でない値・無限を検めるのに読む** (``Emitter`` と同じ)。
    var numbers: [Float] {
        switch self {
        case .plane(let angle): [angle.lowerBound, angle.upperBound]
        case .sphere: []
        }
    }

    /// 1 つぶんの向き (長さ 1) を引く。
    ///
    /// **引く回数は種類ごとに決まっている** (面内 1 回・全方位 2 回)。`Emitter.sample` と同じ
    /// 約束で、回数が揺れる書き方をすると、向きを差し替えた瞬間にその後の乱数の列全体がずれる。
    ///
    /// **面内は、幅が 0 でも 1 回引く。** 向きを `angle` の幅で渡していた頃と同じ回数・同じ式で、
    /// `toward` を省いた呼び出しは、種を決めた粒の値を変えない ([#1042])。
    ///
    /// [#1042]: https://github.com/mokume-metal/mokume/issues/1042
    func sample(using randomness: inout Randomness) -> SIMD3<Float> {
        switch self {
        case .plane(let angle):
            let turn = randomness.value(from: angle.lowerBound, to: angle.upperBound)
            return SIMD3(cos(turn), sin(turn), 0)
        case .sphere:
            // **高さ (z) を一様に引く。** 球面は高さで等間隔に輪切りにすると、どの帯も面積が
            // 等しい。仰角を角度のまま一様に引くと極へ寄る (`Emitter.sphere` と同じ理由)
            let around = randomness.unitValue() * 2 * .pi
            let height = randomness.unitValue() * 2 - 1
            let ring = sqrt(max(0, 1 - height * height))
            return SIMD3(cos(around) * ring, sin(around) * ring, height)
        }
    }
}
