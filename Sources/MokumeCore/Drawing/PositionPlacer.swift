// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// 数の並びを置き場所として読む道 (``Canvas/shape(_:at:layout:)``) の計算の入口。
///
/// **粒の旗・scan・詰めると同じ原文から取る。** 旗と詰めるだけが置き場所用の入口で、scan は
/// 粒のもの (`mokume_particleScan`) をそのまま使う。面に 1 度だけ組む — 位置の並びごとに原文を
/// 組むと、並びの数だけ同じものを組む。
struct PositionKernels {
    /// 置ける位置に旗を立てる計算。
    let flag: Computation
    /// 旗を数える 1 段ぶんの計算。段の数だけ積む。
    let scan: Computation
    /// 置ける位置だけを詰めて、置き場所と描く引数を書く計算。
    let place: Computation

    static let flagName = "mokume_positionFlags"
    static let placeName = "mokume_positionPlace"
}

/// 数の並び 1 本を置き場所として読むための、常駐の置き場。
///
/// **位置の並び (``Numbers``) ごとに 1 つ、面が持つ** (``Canvas/PositionLayouts``)。置き場所・描く引数・
/// 旗の段を毎フレーム確保しない ([ADR-0023] 決定 5)。容量は並びの長さの 1/3 から決まり、並びは
/// 長さが変わらないので、置き場の大きさも変わらない。
///
/// 旗の段 (``levels``) は呼び出しをまたいで共有し、毎回の指定・置き場所・描く引数は呼び出しごとの組
/// (``Draw``) に分ける。同じ描き切りの中で何度呼んでも、1 回目の計算が 2 回目の指定を読んだり、
/// 1 回目の列が 2 回目の置き場所で描かれたりしない (``Particles/Draw`` と同じ理由)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class PositionPlacer {
    /// 1 回の呼び出しが書き、読む置き場の組。
    struct Draw {
        /// 毎回の指定 (変換と段の頭)。並びの正本は `Particles.metal` の「数の並びを置き場所として読む」。
        let parameters: Numbers
        /// 描画へ渡す置き場所の並び。**先頭から置けた数ぶんだけが意味を持つ。**
        let instances: Numbers
        /// 描く引数 (`MTLDrawPrimitivesIndirectArguments`)。GPU が書き、CPU は読まない。
        let arguments: Numbers
    }

    /// 指定の長さ。変換 16・面の向き 12・段の数・頂点の数・段の頭 5・予備 5。
    static let parameterFloats = 40
    /// 置き場所 1 つの float の数。
    private static let instanceFloats = MemoryLayout<SolidInstance>.stride / MemoryLayout<Float>.stride

    /// 置ける位置の数の上限 (位置の並びの長さの 1/3)。
    let capacity: Int
    /// 読み元の並び。**弱く持つ** — 手放された並びの置き場を、面が次の呼び出しで畳める
    /// (``Canvas/PositionLayouts``)。
    weak var source: Numbers?
    /// 旗の段。段ごとの長さと頭は容量から決まる (``Particles/levelLengths(capacity:)``)。
    let levels: Numbers
    /// 段ごとの頭 [長さ, 読む段の頭, 書く段の頭]。**作るときに 1 度書く。**
    let levelHeaders: [Numbers]
    let levelLengths: [Int]
    let levelOffsets: [Int]

    /// 組。**先頭は作るときに確保し**、2 つ目からは、まだ読まれていない組しか無いときに 1 つずつ足す。
    private(set) var draws: [Draw]
    /// 組ごとの使われ方の帳簿。粒と同じ規則で選ぶ (``DrawClaims``)。
    private var claims = DrawClaims()
    /// 組を足すときに投げる失敗。**検査が差し替える** (確保の失敗は検査の中で起こせない)。
    var drawAllocationFailureForTesting: RenderFailure? {
        get { claims.allocationFailureForTesting }
        set { claims.allocationFailureForTesting = newValue }
    }

    /// スキャンの段の数。容量 1 なら 0 (旗そのものが置ける数)。
    var scanCount: Int { levelLengths.count - 1 }

    init(source: Numbers, capacity: Int, gpu: RenderDevice) throws(RenderFailure) {
        guard capacity >= 1 else { throw .invalidCount(capacity) }
        let lengths = Particles.levelLengths(capacity: capacity)
        // 段の頭を渡せる数を超える容量は数え切れない (256^4 = 2^32 個より上)
        guard lengths.count <= Particles.maximumLevels else {
            throw .bufferUnavailable(byteCount: Int.max)
        }
        let (places, overflowed) = capacity.multipliedReportingOverflow(by: Self.instanceFloats)
        guard !overflowed else { throw .bufferUnavailable(byteCount: Int.max) }

        var offsets: [Int] = []
        var offset = 0
        for length in lengths {
            offsets.append(offset)
            offset += length
        }
        var headers: [Numbers] = []
        for _ in 0..<(lengths.count - 1) { headers.append(try Numbers(gpu: gpu, count: 4)) }

        self.capacity = capacity
        self.source = source
        self.levelLengths = lengths
        self.levelOffsets = offsets
        self.levels = try Numbers(gpu: gpu, count: offset)
        self.levelHeaders = headers
        self.draws = [
            Draw(
                parameters: try Numbers(gpu: gpu, count: Self.parameterFloats),
                instances: try Numbers(gpu: gpu, count: places),
                arguments: try Numbers(gpu: gpu, count: Particles.argumentFloats))
        ]

        // 段の頭は容量から決まるので、**ここで 1 度だけ書く** (粒と同じ)
        for (level, header) in headers.enumerated() {
            header.set([
                Float(bitPattern: UInt32(lengths[level])),
                Float(bitPattern: UInt32(offsets[level])),
                Float(bitPattern: UInt32(offsets[level + 1])),
                0,
            ])
        }
    }

    /// `canvas` のこの呼び出しが使う置き場の組を選ぶ。**まだ読まれていない組は使わない** —
    /// 選び方は粒と同じ 1 つの規則 (``DrawClaims``・``Particles/claimDraw(by:)``。#1656 の持ち越した
    /// 落とす列への尋ね方も含む) で、空きが無ければ 1 つ足す。足すのに失敗したら投げる。
    func claimDraw(by canvas: Canvas) throws(RenderFailure) -> Draw {
        let index = try claims.claim(
            by: canvas,
            instances: { draws[$0].instances },
            addDraw: { () throws(RenderFailure) in
                let first = draws[0]
                let gpu = first.parameters.gpu
                draws.append(
                    Draw(
                        parameters: try Numbers(gpu: gpu, count: first.parameters.count),
                        instances: try Numbers(gpu: gpu, count: first.instances.count),
                        arguments: try Numbers(gpu: gpu, count: first.arguments.count)))
            })
        return draws[index]
    }

    /// 呼び出しごとの指定を書く。
    ///
    /// - Parameters:
    ///   - world: いまの変換。置き場所の行列は、これに位置の平行移動を掛けたもの
    ///   - normal: 面の向きを移す行列。**位置を動かしても変わらない**ので、変換のものを 1 つ渡す
    ///   - vertexCount: 描く頂点の数 (形の区間の頂点の数)
    func write(into draw: Draw, world: simd_float4x4, normal: simd_float3x3, vertexCount: Int) {
        draw.parameters.write(at: 0, count: Self.parameterFloats) { values in
            for column in 0..<4 {
                let vector = world[column]
                for row in 0..<4 { values[column * 4 + row] = vector[row] }
            }
            for column in 0..<3 {
                let vector = normal[column]
                for row in 0..<3 { values[16 + column * 4 + row] = vector[row] }
                values[16 + column * 4 + 3] = 0
            }
            // 整数は **ビット列のまま**置く (`Float` に直すと 2^24 を超えたところで丸まる)
            values[28] = Float(bitPattern: UInt32(scanCount))
            values[29] = Float(bitPattern: UInt32(clamping: vertexCount))
            for slot in 0..<Particles.maximumLevels {
                let offset = slot < levelOffsets.count ? levelOffsets[slot] : 0
                values[30 + slot] = Float(bitPattern: UInt32(offset))
            }
            for index in 35..<Self.parameterFloats { values[index] = 0 }
        }
    }
}
