// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 描く前に計算して、その結果を絵にする。
///
/// **見どころは、絵が図形の集まりではないこと。** 場を描く図形は全画面の矩形 1 枚だけで、
/// 模様は毎フレーム GPU が 160×90 の格子へ書いた数から出ている。図形を 14400 個置いて
/// 同じ絵を作ることもできるが、そのときは CPU が 14400 回の呼び出しを払う。
///
/// **起伏も色の段も、同じ数から出ている。** 塗りは画素ごとに隣のマスとの差から傾きを取り、
/// 左上からの光を当てる — 陰影のための図形も法線の並びも持たない。等高線は細線と 5 本ごとの
/// 主線の 2 種で、どちらも画素の幅 (`fwidth`) で太さを揃える。
///
/// **輪は CPU が置いている。** 30 フレームに 1 度だけ ``Sketch/read(_:)`` で場を引き戻し、
/// いちばん高いところを探して印を置く。毎フレーム引くと CPU と GPU が交互に動く形になるので、
/// **要るときだけ引く**という面の言い分をそのまま書いてある。印が次の頂へ滑って移るのは、
/// 引き戻す間隔が絵に出ているからである。札の数も CPU が読んだ値である。
///
/// **下の帯は、その行の断面である。** CPU が見つけた行の番号を ``Numbers/set(_:at:)`` で
/// GPU へ返し、1 次元の計算が場からその 1 行だけを切り出す。場は `reads:` で渡すので、
/// **場を書く計算より後に走ることは宣言から導かれる** — 待つ仕掛けはどこにも書いていない。
/// 横に引いた線が、いま切り出している行で、印から下ろした線が帯の上の同じ点を指す。
///
/// 時計はフレーム番号から導くので、**同じ番号のフレームは何度描いても同じ絵**になる。
final class FieldAndFlow: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "field and flow")
    }

    /// 場の細かさ。**画面の画素数より 1 桁半少ない** — 場は絵の下書きであって絵ではない。
    /// 粗すぎると、混ぜても等高線と陰影にマスの段が出る
    private let columns = 160
    private let rows = 90

    /// 場を引き戻す間隔 (フレーム)。**毎フレームは引かない。**
    private let readEvery = 30

    private var field: Numbers?
    private var stir: Computation?
    private var paint: Shader?

    /// 切り出す行の番号。**CPU が書き、GPU が読む** — 1 個だけの並び。
    private var probe: Numbers?
    /// 切り出した断面。格子の 1 行ぶん。
    private var profile: Numbers?
    /// 場から 1 行を切り出す計算。**1 次元**で、列 1 本につき 1 本走る。
    private var slice: Computation?
    /// 断面を帯に描く塗り。
    private var graph: Shader?
    /// 帯の上端と下端 (画面の高さに対する割合)。
    private let band = (top: Float(0.8), bottom: Float(0.96))

    /// 引き戻した場の、いちばん高かったところ (画面の座標)。
    private var peak: (x: Float, y: Float) = (480, 270)
    /// そのときの高さ。札と、帯の上の点に使う。
    private var peakHeight: Float = 0
    /// そのときの行。**断面を切り出す行**として GPU へ返す。
    private var peakRow = 45
    /// 印を置いている位置。頂へ滑って追いつく。
    private var shown: (x: Float, y: Float) = (480, 270)

    func setup() throws {
        field = try makeNumbers(count: columns * rows)
        field?.fill(0)

        // 描く前に走る側。**格子 1 マスにつき 1 本**走り、位置と時刻だけから値を決める。
        // 前のフレームの値を読まないので、どのフレームから始めても同じ場が出る
        stir = try makeComputation(
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

                // 座標をゆっくり歪めてから波を重ねる。縞ではなく、尾根と谷が
                // 流れながら形を変える地形になる
                float2 s = p * float2(1.78, 1.0);
                s += 0.22 * float2(sin(s.y * 4.1 + t * 0.5), sin(s.x * 3.3 - t * 0.4));
                s += 0.11 * float2(sin(s.y * 7.9 - t * 0.7), sin(s.x * 6.7 + t * 0.6));
                float wave = sin(s.x * 4.6 + t * 0.6)
                           + sin(s.y * 5.3 - t * 0.5)
                           + 0.6 * sin((s.x - s.y) * 7.1 + t * 0.9);

                // 中ほどを高くする。輪を置く先が縁に張り付かないように。
                // **落とし方は控えめにする** — 深く落とすと縁が黒く潰れ、
                // そこにも場があることが絵から読めなくなる
                float bowl = clamp(1.0 - length(p - 0.5) * 0.9, 0.0, 1.0);
                float base = clamp(0.5 + wave * 0.2, 0.0, 1.0);

                field[at.y * uint(grid.x) + at.x] = base * (0.45 + 0.55 * bowl);
            }
            """,
            name: "stir",
            values: ["grid": .pair(Float(columns), Float(rows)), "time": 0])

        // 場を色にする側。**格子より画素のほうが細かい**ので、隣の 4 マスから混ぜて読む
        paint = try createShader(
            """
            static inline float mokume_cell(Fragment in, float2 grid, float2 at) {
                float2 clamped = clamp(at, float2(0.0), grid - 1.0);
                uint index = uint(clamped.y) * uint(grid.x) + uint(clamped.x);
                return in.numbers[index];
            }

            // 場の座標 spot での値。隣の 4 マスから混ぜる
            static inline float mokume_heat(Fragment in, float2 grid, float2 spot) {
                float2 base = floor(spot);
                float2 t = spot - base;
                float a = mokume_cell(in, grid, base);
                float b = mokume_cell(in, grid, base + float2(1.0, 0.0));
                float c = mokume_cell(in, grid, base + float2(0.0, 1.0));
                float d = mokume_cell(in, grid, base + float2(1.0, 1.0));
                return mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
            }

            // 値を色の段へ。深い紺 → 青緑 → 琥珀 → 淡い白
            static inline float3 mokume_ramp(float v) {
                float3 deep = float3(0.015, 0.025, 0.06);
                float3 teal = float3(0.02, 0.24, 0.30);
                float3 amber = float3(0.95, 0.52, 0.16);
                float3 light = float3(1.0, 0.9, 0.72);
                v = clamp(v, 0.0, 1.0);
                if (v < 0.35) { return mix(deep, teal, smoothstep(0.0, 0.35, v)); }
                if (v < 0.7) { return mix(teal, amber, smoothstep(0.35, 0.7, v)); }
                return mix(amber, light, smoothstep(0.7, 1.0, v));
            }

            float4 paint(Fragment in, Values values) {
                float2 grid = values.grid;
                // 場の座標へ移す。マスの真ん中が中心に来るよう半マスずらす
                float2 spot = in.place * grid - 0.5;
                float heat = mokume_heat(in, grid, spot);

                // 隣どうしの差で傾きを取り、左上からの光で起伏にする
                float2 slope = float2(
                    mokume_heat(in, grid, spot + float2(1.0, 0.0)) - mokume_heat(in, grid, spot - float2(1.0, 0.0)),
                    mokume_heat(in, grid, spot + float2(0.0, 1.0)) - mokume_heat(in, grid, spot - float2(0.0, 1.0)));
                float3 normal = normalize(float3(-slope * 22.0, 1.0));
                float light = clamp(dot(normal, normalize(float3(-0.6, -0.7, 0.7))), 0.0, 1.0);

                // 場の値はおよそ 0.15…0.95 に収まるので、色の段の端まで使うよう広げる
                float3 tint = mokume_ramp((heat - 0.15) / 0.8) * (0.2 + 1.05 * light);

                // 等高線。細線と 5 本ごとの主線を、画素の幅で滑らかに引く
                float level = heat * 30.0;
                float near = abs(fract(level - 0.5) - 0.5) / max(fwidth(level), 1e-4);
                float major = level / 5.0;
                float nearMajor = abs(fract(major - 0.5) - 0.5) / max(fwidth(major), 1e-4);
                float thin = 1.0 - smoothstep(0.3, 1.0, near);
                float thick = 1.0 - smoothstep(0.5, 1.5, nearMajor);
                tint = mix(tint, float3(1.0, 0.94, 0.84), thin * 0.1 + thick * 0.45);
                return float4(tint, 1.0);
            }
            """,
            values: ["grid": .pair(Float(columns), Float(rows))])

        // 切り出す行は CPU が決める。**書くのはいつでもよい** — 書いた値は次の描き切りが届ける
        probe = try makeNumbers(count: 1)
        probe?.set(Float(peakRow), at: 0)
        profile = try makeNumbers(count: columns)
        profile?.fill(0)

        // **1 次元の計算。** 束ねる先は `reads + writes` の順に buffer(0), (1), … となる
        slice = try makeComputation(
            """
            kernel void slice(device const float *field [[buffer(0)]],
                              device const float *probe [[buffer(1)]],
                              device float *profile [[buffer(2)]],
                              constant Values &values [[buffer(MOKUME_VALUES)]],
                              uint id [[thread_position_in_grid]])
            {
                uint columns = uint(values.columns);
                if (id >= columns) { return; }
                uint row = uint(probe[0]);
                profile[id] = field[row * columns + id];
            }
            """,
            name: "slice",
            values: ["columns": .number(Float(columns))])

        // 断面を帯にする。**高さがそのまま値**で、帯の下から塗り上げる
        graph = try createShader(
            """
            static inline float mokume_sample(Fragment in, float columns, float i) {
                return in.numbers[uint(clamp(i, 0.0, columns - 1.0))];
            }

            float4 paint(Fragment in, Values values) {
                float columns = values.columns;
                float2 band = values.band;
                float y = (in.place.y - band.x) / (band.y - band.x);

                // 列の間は前後 4 本から曲線で結ぶ (Catmull-Rom)。直線で結ぶと折れ線になる
                float spot = clamp(in.place.x * columns - 0.5, 0.0, columns - 1.0);
                float i = floor(spot);
                float t = spot - i;
                float p0 = mokume_sample(in, columns, i - 1.0);
                float p1 = mokume_sample(in, columns, i);
                float p2 = mokume_sample(in, columns, i + 1.0);
                float p3 = mokume_sample(in, columns, i + 2.0);
                float level = 0.5 * (2.0 * p1 + (p2 - p0) * t
                    + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
                    + (3.0 * (p1 - p2) + p3 - p0) * t * t * t);
                float top = 1.0 - clamp(level, 0.0, 1.0);

                // 線からの距離を画素で測る。坂でも平らでも同じ太さに見える
                float d = y - top;
                float pixels = d / max(fwidth(d), 1e-4);
                float core = 1.0 - smoothstep(0.6, 1.6, abs(pixels));
                float glow = exp(-abs(pixels) / 7.0);

                // 断面の下は値の色で、下へ行くほど薄く。目盛りの横線を 4 等分に
                float under = smoothstep(-0.5, 0.5, pixels) * (1.0 - 0.75 * clamp(d / (1.0 - top + 1e-3), 0.0, 1.0));
                float3 hot = mix(float3(0.02, 0.30, 0.36), float3(1.0, 0.56, 0.18), clamp(level, 0.0, 1.0));
                float rule = 1.0 - smoothstep(0.0, 1.0, abs(fract(y * 4.0 + 0.5) - 0.5) / max(fwidth(y * 4.0), 1e-4));
                float3 color = float3(0.012, 0.018, 0.035) + hot * under * 0.5 + rule * 0.04
                    + core * float3(1.0, 0.9, 0.75) + glow * hot * 0.35;
                return float4(color, 0.72 + 0.28 * max(core, under));
            }
            """,
            name: "graph",
            values: [
                "columns": .number(Float(columns)),
                "band": .pair(band.top, band.bottom),
            ])
    }

    func draw() {
        guard let field, let stir, let paint else { return }

        stir.set("time", .number(time))
        compute(stir, over: columns, by: rows, writes: [field])
        // 場を読む計算。**`reads:` に場を書いたので、上の計算が終わってから走る**
        if let slice, let probe, let profile {
            compute(slice, over: columns, reads: [field, probe], writes: [profile])
        }

        // **要るときだけ引く。** 引くとその場で走らせて完了まで待つので、
        // 毎フレーム引けば CPU と GPU が交互に動く形になる
        if frameCount % readEvery == 1 { findPeak(in: read(field)) }

        background(5, 8, 16)
        // **塗りの指定はフレームをまたいで残る。** 下で `noFill()` にしているので、
        // ここで戻さないと 2 フレーム目から矩形が 1 枚も出ない (絵は出るので気付きにくい)
        fill(255, 255, 255)
        noStroke()
        numbers(field)
        shader(paint)
        rect(0, 0, width, height)
        resetShader()
        resetNumbers()

        // 断面の帯。**塗りの規約は同じで、読む並びだけが違う**
        if let graph, let profile {
            numbers(profile)
            shader(graph)
            rect(0, height * band.top, width, height * (band.bottom - band.top))
            resetShader()
            resetNumbers()
        }

        // CPU が置く側。**GPU が書いた数を CPU が読んで初めて置ける印**である。
        // 読み戻すのは 30 フレームに 1 度なので、印は次の頂へ滑って移る
        shown.x += (peak.x - shown.x) * 0.15
        shown.y += (peak.y - shown.y) * 0.15
        let ink = (r: Float(255), g: Float(242), b: Float(220))

        // いま切り出している行。**帯の断面はこの線の上の値である** — 印から帯へ線を下ろし、
        // 帯の上の同じ点に打つ
        let rowY = (Float(peakRow) + 0.5) / Float(rows) * height
        let bandY = height * (band.top + (1 - peakHeight) * (band.bottom - band.top))
        strokeWeight(1)
        stroke(ink.r, ink.g, ink.b, 40)
        line(0, rowY, width, rowY)
        stroke(ink.r, ink.g, ink.b, 90)
        line(shown.x, shown.y + 22, shown.x, bandY - 6)
        noStroke()
        fill(ink.r, ink.g, ink.b)
        circle(shown.x, bandY, 6)

        // 細い輪と、切れ目のある照準。中心に点
        noFill()
        stroke(ink.r, ink.g, ink.b, 220)
        circle(shown.x, shown.y, 28)
        for step in 0..<4 {
            let angle = Float(step) * .pi / 2
            line(
                shown.x + cos(angle) * 20, shown.y + sin(angle) * 20,
                shown.x + cos(angle) * 30, shown.y + sin(angle) * 30)
        }
        noStroke()
        fill(ink.r, ink.g, ink.b)
        circle(shown.x, shown.y, 4)

        // 札。CPU が読んだ値をそのまま出す
        textFont("Menlo")
        textSize(11)
        fill(ink.r, ink.g, ink.b, 210)
        text("peak \(Int(peakHeight * 100)) %  ·  row \(peakRow)", shown.x + 36, shown.y - 8)

        effects([.vignette(amount: 0.45)])
    }

    /// 引き戻した場から、いちばん高いマスを探して画面の座標へ移す。
    private func findPeak(in values: [Float]) {
        guard values.count == columns * rows else { return }
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        let column = Float(best % columns) + 0.5
        let row = Float(best / columns) + 0.5
        peak = (map(column, 0, Float(columns), 0, width), map(row, 0, Float(rows), 0, height))
        peakHeight = values[best]
        peakRow = best / columns
        // 見つけた行を GPU へ返す。**待たない** — 次の描き切りが届ける
        probe?.set(Float(peakRow), at: 0)
    }
}
