// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 長く回しても重くならないことを、**多数フレームで数えて**見る。
///
/// ## なぜ数える形でしか見られないか
///
/// 「毎フレーム走る経路は、フレームごとに新しい置き場を確保しない」は、破れても例外が
/// 出ない。絵は正しく出たまま、走らせ続けたときにだけ少しずつ重くなる。単発の検査では
/// 1 度目の確保と 2 度目の確保が見分けられないので、**回した数だけ増えるかどうか**を
/// 見るしかない (親フェーズ [#385] の全体条件 2)。
///
/// ## 数えるものは既にある
///
/// ``RenderDevice`` を通して確保した資源はすべて ``RenderDevice/makeResident(_:)`` を
/// 通り、常駐の集合に入る。集合から外れるのは差し出す面の環だけなので、
/// `residencySet.allocationCount` は**この土台が確保した資源の総数**そのものである。
/// 数えるための機構を足していないのは、既にあるもので測れるからである ([ADR-0008])。
///
/// ## 何を回すか
///
/// M6 で足した段を**全部載せた 1 フレーム**を回す — 計算・粒・効果・拡大・描き場所・
/// 出力段。段ごとに分けて回すと、段と段の間で作られるもの (拡大の中間の面など) が
/// どちらの検査にも入らない。
///
/// [#385]: https://github.com/mokume-metal/mokume/issues/385
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
@Suite(
    "長く回しても増えない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FrameGrowthTests {
    /// 温めるフレーム数。**最初の数フレームは確保して当たり前**なので数えない
    /// (置き場は要る分だけ、要るときに作られる)。
    private static let warmUp = 24
    /// 数えるフレーム数。温めたあとの伸びは、ここに比例して出る。
    private static let longRun = 200

    @Test("毎フレーム走る経路が、フレームごとに置き場を確保しない")
    func theFramePathStopsAllocating() throws {
        let gpu = try RenderDevice()
        let stage = try Stage(gpu: gpu)

        for _ in 0..<Self.warmUp { try stage.frame() }
        let settled = gpu.residencySet.allocationCount

        for _ in 0..<Self.longRun { try stage.frame() }
        let after = gpu.residencySet.allocationCount

        #expect(
            after == settled,
            """
            \(Self.longRun) フレームで置き場が \(after - settled) 個増えた
            (温めた後は 1 つも増えないはず)。

            毎フレーム走る経路のどこかが、フレームごとに新しい置き場を作っている
            ([ADR-0023] 決定 5)。破れても例外は出ず、長く走らせたときにだけ重くなるので、
            ここで止める。増えた数がフレーム数に比例していれば毎フレーム 1 つ、
            粒の数に比例していれば粒ごとに 1 つである。
            """)
    }

    /// 置き場を取り直させる回数。倍増で伸びるので、**要求を毎回倍にする**。
    private static let regrowths = 6

    @Test("置き場を何度も取り直しても、常駐の集合が増え続けない")
    func regrowingBuffersDoesNotPileUpResidency() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 64, height: 64)
        let canvas = try Canvas(target: target, gpu: gpu)

        /// 図形を `count` 個置く 1 フレーム。数を増やすと置き場が足りなくなり、
        /// ``GrowableBuffer`` が全スロットを取り直す。
        func frame(shapes count: Int) throws {
            try canvas.draw {
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                for index in 0..<count {
                    canvas.fill(.opaque(red: Float(index % 8) / 8, green: 0.4, blue: 0.6))
                    canvas.rect(Float(index % 64), Float((index / 64) % 64), 1, 1)
                }
            }
        }

        // **環のスロットが全部埋まるまで温める。** 最初にそのスロットが回ってきた
        // フレームは確保して当たり前である
        for _ in 0..<RenderDevice.defaultSlotCount { try frame(shapes: 64) }
        let settled = gpu.residencySet.allocationCount

        var shapes = 64
        for _ in 0..<Self.regrowths {
            shapes *= 2
            for _ in 0..<RenderDevice.defaultSlotCount { try frame(shapes: shapes) }
        }
        let after = gpu.residencySet.allocationCount

        #expect(
            after == settled,
            """
            置き場を \(Self.regrowths) 回取り直したら、常駐の集合が \(after - settled) 個増えた
            (取り直しは古いほうを外すので、増減 0 のはず)。

            倍増で使い回す置き場が、取り直した古いほうを常駐の集合から外していない
            ([#738](https://github.com/mokume-metal/mokume/issues/738))。絵は正しく出たまま、
            長く走らせたときにだけメモリを食う。
            """)
    }

    /// 段を全部載せた 1 フレーム。**フレームをまたいで持つものは、ここで 1 度だけ作る。**
    private final class Stage {
        /// 場の細かさ。
        static let cells = 256

        let target: RenderTarget
        let canvas: Canvas
        let trail: Canvas
        let field: Numbers
        let stir: Computation
        let paint: Shader
        let dust: Particles
        var randomness = Randomness(seed: 20_260_830)
        var step = 0

        init(gpu: RenderDevice) throws {
            target = try RenderTarget(gpu: gpu, width: 128, height: 128)
            // **描く細かさを落として拡大させる。** 拡大の段も毎フレーム走る経路である
            canvas = try Canvas(output: target, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
            trail = try canvas.createGraphics(64, 64)
            field = try canvas.makeNumbers(count: Self.cells)
            field.fill(0)
            stir = try canvas.makeComputation(
                """
                kernel void stir(device float *field [[buffer(0)]],
                                 constant Values &values [[buffer(MOKUME_VALUES)]],
                                 uint id [[thread_position_in_grid]])
                {
                    field[id] = 0.5 + 0.5 * sin(float(id) * 0.05 + values.time);
                }
                """,
                name: "stir", values: ["time": 0])
            paint = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    uint index = uint(clamp(in.place.x, 0.0, 0.999) * values.cells);
                    float heat = in.numbers[index];
                    return float4(heat, heat * 0.5, 0.2, 1.0);
                }
                """,
                values: ["cells": .number(Float(Self.cells))])
            dust = try canvas.makeParticles(count: 4000)
        }

        /// 1 フレーム分。**毎フレーム同じ仕事**をする。
        func frame() throws {
            let seconds = Float(step) / 60
            stir.set("time", .number(seconds))
            try canvas.draw {
                canvas.compute(stir, over: Self.cells, writes: [field])
                canvas.background(.display(red: 0.04, green: 0.05, blue: 0.08))

                // 描き場所は消さずに描き足す
                trail.beginDraw()
                trail.noStroke()
                trail.fill(.display(red: 1, green: 0.6, blue: 0.25, alpha: 0.6))
                trail.circle(32 + cos(seconds * 3) * 20, 32 + sin(seconds * 3) * 20, 8)
                trail.endDraw()
                canvas.image(trail, 0, 0)

                // 計算が書いた数をそのまま絵にする
                canvas.noStroke()
                canvas.fill(.display(red: 1, green: 1, blue: 1))
                canvas.numbers(field)
                canvas.shader(paint)
                canvas.rect(0, 96, 128, 32)
                canvas.resetShader()
                canvas.resetNumbers()

                // 粒。**枠は使い回される**ので、寿命が尽きても置き場は増えない
                canvas.emit(
                    dust, from: .point(64, 120), rate: 900, speed: 60...140,
                    angle: (-2.4)...(-0.75), life: 0.6...1.4, size: 2...4,
                    color: .opaque(red: 1, green: 0.72, blue: 0.35), using: &randomness)
                canvas.force(dust, [.gravity(0, 200), .drag(0.25)])
                canvas.particles(dust)

                canvas.effects([
                    .bloom(amount: 0.6, threshold: 0.4, radius: 8),
                    .vignette(amount: 0.5),
                ])
            }
            // 出力段も毎フレーム走る経路である (画面へ出す・書き出すのはここから)
            _ = try target.encodeForDisplay()
            step += 1
        }
    }
}
