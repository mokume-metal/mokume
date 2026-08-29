// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 粒がどこから出るか。
///
/// 使い方は ``Sketch/emit(_:from:rate:speed:angle:life:size:color:)`` にある。
///
/// **出る場所だけを決める。** どちらへ飛ぶかは `angle` が決めるので、形を差し替えても
/// 飛ぶ向きは変わらない — 2 つを 1 つの指定へ混ぜると、形を変えた瞬間に向きまで変わる。
public enum Emitter: Equatable, Sendable {
    /// 1 点から。
    case point(_ x: Float, _ y: Float, _ z: Float = 0)
    /// 2 点を結ぶ線分の上から (どこも同じ確からしさで)。
    case line(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float)
    /// 円の内側から (どこも同じ確からしさで)。
    case circle(_ x: Float, _ y: Float, radius: Float)
    /// 球の内側から (どこも同じ確からしさで)。
    case sphere(_ x: Float, _ y: Float, _ z: Float, radius: Float)

    /// 1 つぶんの出どころを引く。
    ///
    /// **引く回数は形ごとに決まっている** (点 0 回・線 1 回・円 2 回・球 3 回)。回数が
    /// 揺れる書き方をすると、形を差し替えた瞬間に**その後の乱数の列全体**がずれる。
    func sample(using randomness: inout Randomness) -> SIMD3<Float> {
        switch self {
        case .point(let x, let y, let z):
            return SIMD3(x, y, z)
        case .line(let x1, let y1, let x2, let y2):
            let t = randomness.unitValue()
            return SIMD3(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0)
        case .circle(let x, let y, let radius):
            // **半径は平方根で引く。** そのまま引くと中心へ寄る
            let around = randomness.unitValue() * 2 * .pi
            let distance = abs(radius) * sqrt(randomness.unitValue())
            return SIMD3(x + cos(around) * distance, y + sin(around) * distance, 0)
        case .sphere(let x, let y, let z, let radius):
            // 向きを 2 つの角から作り、半径は 3 乗根で引く (円と同じ理由の 3 次元版)
            let around = randomness.unitValue() * 2 * .pi
            let height = randomness.unitValue() * 2 - 1
            let distance = abs(radius) * pow(randomness.unitValue(), 1.0 / 3)
            let ring = sqrt(max(0, 1 - height * height))
            return SIMD3(
                x + cos(around) * ring * distance,
                y + height * distance,
                z + sin(around) * ring * distance)
        }
    }
}
