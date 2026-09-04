// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 描く前に計算して、その結果を絵にする。
///
/// **見どころは、絵が図形の集まりではないこと。** 置いている図形は全画面の矩形 1 枚だけで、
/// 模様は毎フレーム GPU が 96×54 の格子へ書いた数から出ている。図形を 5184 個置いて
/// 同じ絵を作ることもできるが、そのときは CPU が 5184 回の呼び出しを払う。
///
/// **輪は CPU が置いている。** 30 フレームに 1 度だけ ``Sketch/read(_:)`` で場を引き戻し、
/// いちばん高いところを探して印を置く。毎フレーム引くと CPU と GPU が交互に動く形になるので、
/// **要るときだけ引く**という面の言い分をそのまま書いてある。
///
/// 時計はフレーム番号から導くので、**同じ番号のフレームは何度描いても同じ絵**になる。
final class FieldAndFlow: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "field and flow")

    /// 場の細かさ。**画面の画素数より 2 桁少ない** — 場は絵の下書きであって絵ではない。
    private let columns = 96
    private let rows = 54

    /// 場を引き戻す間隔 (フレーム)。**毎フレームは引かない。**
    private let readEvery = 30

    private var field: Numbers?
    private var stir: Computation?
    private var paint: Shader?

    /// 引き戻した場の、いちばん高かったところ (画面の座標)。
    private var peak: (x: Float, y: Float) = (480, 270)
    /// そのときの高さ。輪の太さに使う。
    private var peakHeight: Float = 0

    func setup() {
        field = try? makeNumbers(count: columns * rows)
        field?.fill(0)

        // 描く前に走る側。**格子 1 マスにつき 1 本**走り、位置と時刻だけから値を決める。
        // 前のフレームの値を読まないので、どのフレームから始めても同じ場が出る
        stir = try? makeComputation(
            """
            kernel void stir(device float *field [[buffer(0)]],
                             constant Values &values [[buffer(MOKUME_VALUES)]],
                             uint2 at [[thread_position_in_grid]])
            {
                float2 grid = values.grid;
                if (at.x >= uint(grid.x) || at.y >= uint(grid.y)) { return; }

                // マスの真ん中で引く (画素の真ん中で引く塗りと座標を揃える)
                float2 p = (float2(at) + 0.5) / grid;
                float t = values.time;

                // 向きの違う波を 3 つ重ねる。1 つだけだと縞にしか見えず、
                // 場が「流れている」ことが動きから読めない
                float wave = sin((p.x * 5.4 + t * 0.9) * 1.7)
                           + sin((p.y * 4.6 - t * 0.7) * 1.9)
                           + sin((p.x + p.y) * 6.2 - t * 1.3);

                // 中ほどを高くする。輪を置く先が縁に張り付かないように。
                // **落とし方は控えめにする** — 深く落とすと縁が黒く潰れ、
                // そこにも場があることが絵から読めなくなる
                float bowl = clamp(1.0 - length(p - 0.5) * 0.9, 0.0, 1.0);
                float base = clamp(0.5 + wave * 0.22, 0.0, 1.0);

                field[at.y * uint(grid.x) + at.x] = base * (0.45 + 0.55 * bowl);
            }
            """,
            name: "stir",
            values: ["grid": .pair(Float(columns), Float(rows)), "time": 0])

        // 場を色にする側。**格子より画素のほうが細かい**ので、隣の 4 マスから混ぜて読む
        paint = try? makeShader(
            """
            static inline float mokume_cell(Fragment in, float2 grid, float2 at) {
                float2 clamped = clamp(at, float2(0.0), grid - 1.0);
                uint index = uint(clamped.y) * uint(grid.x) + uint(clamped.x);
                return in.numbers[index];
            }

            float4 paint(Fragment in, Values values) {
                float2 grid = values.grid;
                // 場の座標へ移す。マスの真ん中が中心に来るよう半マスずらす
                float2 spot = in.place * grid - 0.5;
                float2 base = floor(spot);
                float2 t = spot - base;

                float a = mokume_cell(in, grid, base);
                float b = mokume_cell(in, grid, base + float2(1.0, 0.0));
                float c = mokume_cell(in, grid, base + float2(0.0, 1.0));
                float d = mokume_cell(in, grid, base + float2(1.0, 1.0));
                float heat = mix(mix(a, b, t.x), mix(c, d, t.x), t.y);

                float3 tint = mix(values.low.rgb, values.high.rgb, clamp(heat, 0.0, 1.0));

                // 等高線を 1 本重ねる。**値そのものが読める**ようになり、
                // 混ぜた色だけでは分からない場の形が出る
                float ring = fract(heat * 9.0);
                float line = smoothstep(0.46, 0.5, ring) * (1.0 - smoothstep(0.5, 0.54, ring));
                return float4(tint + line * 0.28, 1.0);
            }
            """,
            values: [
                "grid": .pair(Float(columns), Float(rows)),
                "low": .color(color(13, 18, 33)),
                "high": .color(color(255, 194, 92)),
            ])
    }

    func draw() {
        guard let field, let stir, let paint else { return }

        stir.set("time", .number(time))
        compute(stir, over: columns, by: rows, writes: [field])

        // **要るときだけ引く。** 引くとその場で走らせて完了まで待つので、
        // 毎フレーム引けば CPU と GPU が交互に動く形になる
        if frameCount % readEvery == 1 { findPeak(in: read(field)) }

        background(10, 13, 20)
        // **塗りの指定はフレームをまたいで残る。** 下で `noFill()` にしているので、
        // ここで戻さないと 2 フレーム目から矩形が 1 枚も出ない (絵は出るので気付きにくい)
        fill(255, 255, 255)
        noStroke()
        numbers(field)
        shader(paint)
        rect(0, 0, width, height)
        resetShader()
        resetNumbers()

        // CPU が置く側。**GPU が書いた数を CPU が読んで初めて置ける印**である
        noFill()
        stroke(255, 255, 255, 217)
        strokeWeight(2 + peakHeight * 3)
        circle(peak.x, peak.y, 54 + peakHeight * 26)
        strokeWeight(1)
        line(peak.x - 34, peak.y, peak.x + 34, peak.y)
        line(peak.x, peak.y - 34, peak.x, peak.y + 34)
    }

    /// 引き戻した場から、いちばん高いマスを探して画面の座標へ移す。
    private func findPeak(in values: [Float]) {
        guard values.count == columns * rows else { return }
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        let column = Float(best % columns) + 0.5
        let row = Float(best / columns) + 0.5
        peak = (column / Float(columns) * width, row / Float(rows) * height)
        peakHeight = values[best]
    }
}
