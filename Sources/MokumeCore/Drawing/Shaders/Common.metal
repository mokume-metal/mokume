// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// すべてのフラグメントに**無条件で**前置きされる共通部分。
//
// 前置きを「利用者の断片が既に持っていれば足さない」形の条件分岐にはしない。
// コメントの中に書かれた宣言にまで反応して絵が消えるためで、二重に足されても
// 壊れない形にするほうが安全である。
//
// ここに混ぜ方の全部が入っているので、**組み込みも利用者の断片も同じ合成を通る**。
// 利用者が書くのは「その画素の色」だけで、下地との混ぜ方は書かなくてよい。

#include <metal_stdlib>
using namespace metal;

struct ShapeFragmentIn {
    float4 position [[position]];
    float2 uv;
    float4 color;
    /// 世界の座標での位置。立体だけが使う (平面は 0)。
    float3 worldPosition;
    /// 面の向き。立体だけが使う (平面は 0)。
    float3 normal;
    /// 面の向きを形から求めたか (1 なら両面として扱う)。
    float isDerivedNormal;
    /// **形自身の座標**での位置。立体だけが使う (平面は 0)。
    float3 shapePosition;
    /// 形自身の座標での面の向き。立体だけが使う (平面は 0)。
    float3 shapeNormal;
};

/// 置いた光 1 つぶん。並びは Swift 側の `Light` と一致する。
struct Light {
    /// 色 (線形・明るさの倍率) と、種類。
    float4 colorAndKind;
    /// 世界の座標での位置 (点光源とスポット)。
    float4 position;
    /// 光が**進む向き**と、広がりの外側の余弦 (スポット)。
    float4 directionAndCone;
};

/// この列に効く光が、置き場のどこから何個あるか。と、どこから見ているか。
/// 並びは Swift 側の `Lighting` と一致する。
struct Lighting {
    uint offset;
    uint count;
    /// 16 バイト境界へ揃えるための詰め物 (Swift 側もこの位置を空けている)。
    float2 padding;
    /// 見ている場所。`w` が 1 なら xyz は**視点の位置** (透視)、0 なら
    /// xyz は**見ている側へ向かう一定の向き** (平行)。艶は見る向きで変わるので要る。
    float4 viewer;
    /// 世界をカメラの側へ移す行列。面の向きを視点から見た向きへ移すのに使う。
    float4x4 view;
};

/// この列に効く周囲。並びは Swift 側の `PackedSurroundings` と一致する。
struct Surroundings {
    /// 上の色 (rgb) と、周囲が置かれているか (w)。
    float4 topAndPresence;
    /// 地平の色 (rgb) と、この列が周囲そのものを出すか (w)。
    float4 horizonAndBackdrop;
    /// 下の色 (rgb)。
    float4 bottom;
};

/// この列を描く材質。並びは Swift 側の `PackedMaterial` と一致する。
struct Material {
    /// 周りの光への返し (rgb) と、艶の鋭さ (w)。
    float4 ambientAndShininess;
    /// 自発光 (rgb) と、金属らしさ (w)。
    float4 emissiveAndMetalness;
    /// 旗 — x が 1 なら影を受ける。
    float4 flags;
};

/// 周囲を、ある向きへ見たときの色。
///
/// 縦軸は下向きなので、**上を向くほど `y` は小さい**。上半分は地平から上の色へ、
/// 下半分は地平から下の色へ真っすぐつなぐ。背景も映り込みも**この 1 本から読む**ので、
/// 上下・左右がずれようがない。
static inline float3 mokume_surroundings(Surroundings surroundings, float3 direction) {
    float height = clamp(-normalize(direction).y, -1.0, 1.0);
    float3 horizon = surroundings.horizonAndBackdrop.rgb;
    return height > 0.0
        ? mix(horizon, surroundings.topAndPresence.rgb, height)
        : mix(horizon, surroundings.bottom.rgb, -height);
}

/// 周囲をぜんぶ混ぜた色。粗い面の映り込みが寄っていく先。
static inline float3 mokume_surroundingsAverage(Surroundings surroundings) {
    return (surroundings.topAndPresence.rgb + 2.0 * surroundings.horizonAndBackdrop.rgb
        + surroundings.bottom.rgb) * 0.25;
}

/// フレームを通して変わらない値。並びは Swift 側の `Uniforms` と一致する。
struct Uniforms {
    float time;
    float2 resolution;
    /// 影の縁の破綻を抑える量。
    float shadowBias;
    /// 世界の座標を、光から見た切り取りの立方体へ落とす行列。
    float4x4 shadowMatrix;
    /// x が 1 なら影が焼いてある。y は焼き付け先の 1 画素の大きさ (0…1 の尺度)。
    float4 shadowParams;
    /// 揺らぎの種。`noiseSeed()` が決める。
    uint noiseSeed;
    /// 重ねる枚数と、1 枚ごとの弱まり。`noiseDetail()` が決める。
    uint noiseOctaves;
    float noiseFalloff;
    /// 16 バイト境界へ揃えるための詰め物 (Swift 側もこの位置を空けている)。
    float noisePadding;
};

/// 焼き付けた影の読み方。**比べるのは採取器で、混ぜるのは比べた結果**である。
///
/// 奥行きの面を `compare_func` 付きで読むと、採取器が「比べる値 <= 焼いた奥行き」を
/// 4 近傍それぞれで判定し、その 0 / 1 を bilinear で混ぜて返す (HW PCF)。奥行きそのもの
/// を混ぜてから比べるのではない — それだと比べる相手が「どこにも無い奥行き」になって
/// 縁が濁る。`less_equal` は、かつて手で書いていた `limit <= recorded` の写しである。
constexpr sampler kShadowSampler(
    coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);

/// その点が光から見えているか (1 = 見えている, 0 = 遮られている)。
///
/// **焼いた範囲の外は遮らない。** 範囲は作品が決めるものなので、外側を「影」に
/// すると、範囲を小さくしただけで世界の端が黒く沈む。
static inline float mokume_shadowFactor(
    depth2d<float> baked, float4x4 lightMatrix, float texel, float bias,
    float3 worldPosition, float3 normal, float3 toLight)
{
    float4 clip = lightMatrix * float4(worldPosition, 1.0);
    float3 ndc = clip.xyz / clip.w;
    if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0 || ndc.z > 1.0 || ndc.z < 0.0) { return 1.0; }
    float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);

    // **斜めに当たる面ほど余裕を増やす。** 焼いた 1 画素の中で奥行きが大きく変わる
    // ので、一定の余裕だと自分の影が自分の上に縞として出る
    float slope = clamp(1.0 - dot(normal, toLight), 0.0, 1.0);
    float limit = ndc.z - (bias + bias * 4.0 * slope);

    // **半画素ずらした 4 点を平均する。** 1 点 (bilinear 4 近傍) だけだと縁は 2×2 画素の
    // 幅で移り、かつて 9 点で数えていた 3×3 の箱より硬くなる。半画素ずらした 4 点は
    // それぞれ 2×2 を混ぜるので、足すと 3×3 (中心 4/16・辺 2/16・角 1/16 のテント) に
    // なり、同じ広さの縁をタップ 4 つで得る ([#757])
    //
    // [#757]: https://github.com/mokume-metal/mokume/issues/757
    float half_texel = texel * 0.5;
    float lit = 0.0;
    lit += baked.sample_compare(kShadowSampler, uv + float2(-half_texel, -half_texel), limit);
    lit += baked.sample_compare(kShadowSampler, uv + float2(half_texel, -half_texel), limit);
    lit += baked.sample_compare(kShadowSampler, uv + float2(-half_texel, half_texel), limit);
    lit += baked.sample_compare(kShadowSampler, uv + float2(half_texel, half_texel), limit);
    return lit * 0.25;
}

/// アルファの乗算を戻す。完全に透明な画素には戻すべき色が無いので 0 を返す。
static inline float3 straighten(float4 color) {
    return color.a > 0.0 ? color.rgb / color.a : float3(0.0);
}

/// 面が出す色を、置いた光と材質から決める。**式はこれ 1 本しかない。**
///
/// 式を 2 本持って切り替える形にすると、どの指定が効くかが「いまどちらの式か」に
/// 依存する。1 本なので、材質の 4 つは常に全部が効く。
///
/// ```text
/// 出る色 = 自発光
///        + 周りへの返し · 塗り · (底上げの光の合計)
///        + (1 − 金属らしさ) · 塗り · (向きを持つ光の合計)
///        + 周りへの返し · 塗り · (周囲を面の向きで読んだ色)
///        + 艶 (点光源のぶん + 周囲を反射の向きで読んだぶん)
/// ```
///
/// **既定の材質では、材質が無かったときと 1 ビットも変わらない。** 周りへの返しは
/// 白 (= 1 を掛けるだけ)、金属らしさは 0 (= 1 を掛けるだけ)、自発光と艶は 0 なので、
/// 足し込む順序も掛ける順序も以前と同じままである — 順序が変わると最下位ビットが
/// 動き、触っていない絵の台帳まで動く。
///
/// **光を 1 つも置いていなければ、面はそのままの色で出る** (呼ぶ側が数で分岐する)。
/// 材質もそのとき効かないので、呼ぶ側が警告を出す。
///
/// 色は**アルファ乗算済み**のまま扱う ([ADR-0011] 決定 4)。映り込みの色 (`f0`) だけは
/// 乗算を戻してから作る — 半透明の面の金属色が、透け具合で濁らないようにするため。
static inline float3 mokume_shade(
    constant Light *lights, uint offset, uint count,
    float3 worldPosition, float3 normal, float4 viewer,
    float4 color, Material material, Surroundings surroundings,
    depth2d<float> baked, constant Uniforms &uniforms)
{
    float3 base = color.rgb;
    float3 ambientResponse = material.ambientAndShininess.rgb;
    float shininess = material.ambientAndShininess.w;
    float3 emissive = material.emissiveAndMetalness.rgb;
    float metalness = clamp(material.emissiveAndMetalness.w, 0.0, 1.0);

    // 艶の鋭さ (大きいほど鋭い) を粗さへ写す。**0 は「艶を出さない」の合図**なので
    // 式に入れない — 手本の綴りをそのまま採ったため、向きがここで逆になる
    float roughness = shininess > 0.0 ? clamp(sqrt(2.0 / (shininess + 2.0)), 0.03, 1.0) : 1.0;
    float spread = roughness * roughness;
    // 映り込みの色。非金属はどの色でもほぼ同じ弱い映り込み、金属は塗りそのものを映す
    float3 f0 = mix(float3(0.04), straighten(color), metalness);

    // **影が減衰させるのは直接の光だけ。** 底上げの光・周囲・自発光は影の中でも残り、
    // 周りへの返しは影の内外を問わず効く
    bool receivesShadow = material.flags.x > 0.5 && uniforms.shadowParams.x > 0.5;
    bool foundCaster = false;

    float3 total = float3(0.0);
    float3 gloss = float3(0.0);
    float3 n = normalize(normal);
    float3 toEye = viewer.w > 0.5 ? normalize(viewer.xyz - worldPosition) : normalize(viewer.xyz);
    for (uint index = 0; index < count; index++) {
        constant Light &light = lights[offset + index];
        uint kind = uint(light.colorAndKind.w);
        float3 color = light.colorAndKind.rgb;

        if (kind == kAmbientLight) {
            // 周りの光は、金属でも非金属でも塗りの色で返る — 一様な周りを拡散する
            // のと映すのは同じ式になるので、ここで金属かどうかを見ない。**金属が
            // 真っ黒にならないのはこのため**で、映り込む先が入ったら差し替わる
            total += color * ambientResponse;
            continue;
        }

        // 面から光源へ向かう向き。平行光は「光が進む向き」の逆
        float3 toLight;
        float cone = 1.0;
        if (kind == kDirectionalLight) {
            toLight = normalize(-light.directionAndCone.xyz);
        } else {
            float3 offsetToLight = light.position.xyz - worldPosition;
            toLight = normalize(offsetToLight);
            if (kind == kSpotLight) {
                // 広がりの外は当たらない。縁は少しなめらかにする
                float alignment = dot(normalize(light.directionAndCone.xyz), -toLight);
                float outer = light.directionAndCone.w;
                cone = smoothstep(outer, mix(outer, 1.0, 0.25), alignment);
            }
        }

        float3 incoming = color * max(dot(n, toLight), 0.0) * cone;
        // **影を落とすのは、置いてあるうちの最初の向きを持つ光** (Swift 側と同じ規則)。
        // 拡散も艶もここから作るので、掛けるのはこの 1 か所で足りる
        if (kind == kDirectionalLight && !foundCaster) {
            foundCaster = true;
            if (receivesShadow) {
                incoming *= mokume_shadowFactor(
                    baked, uniforms.shadowMatrix, uniforms.shadowParams.y,
                    uniforms.shadowBias, worldPosition, n, toLight);
            }
        }
        total += incoming * (1.0 - metalness);

        if (shininess > 0.0) {
            // 粗さで広がる山 (GGX) · 遮り合い · 見る角での映り込みの強さ
            float3 halfway = normalize(toLight + toEye);
            float nl = max(dot(n, toLight), 0.0);
            float nv = max(dot(n, toEye), 1e-4);
            float nh = max(dot(n, halfway), 0.0);
            float vh = max(dot(toEye, halfway), 0.0);
            float spread2 = spread * spread;
            // `peak` は N·H ∈ [0, 1] で単調に減り、山の頂 (N·H = 1) で最小の `spread2` を取る。
            // **下から止めるのはその最小値で、定数ではない。** 止まるのは丸め (N·H が 1 を
            // わずかに超える・`spread2 - 1` の丸め) で最小値を割ったときだけで、正しい値は
            // 1 つも変わらない。粗さの下限 (0.03) があるので分母は π · 0.03⁸ ≈ 2e−12 を
            // 割らず、0 では割らない。以前の `max(π · peak², 1e-6)` は shininess 80 ほどから
            // 頂に掛かり、鋭くするほど艶が暗くなっていた (#1407)
            float peak = max(nh * nh * (spread2 - 1.0) + 1.0, spread2);
            float distribution = spread2 / (M_PI_F * peak * peak);
            float k = spread / 2.0;
            float shadowing = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
            float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
            gloss += incoming * distribution * shadowing * fresnel / max(4.0 * nl * nv, 1e-4);
        }
    }
    if (surroundings.topAndPresence.w > 0.5) {
        // **面の向きで読むぶん。** 底上げの光とまったく同じ位置に足す — 一様な周りを
        // 拡散するのと映すのは同じ式なので、ここでも金属かどうかを見ない。**周囲を
        // 置くと金属が「上が空・下が地面」に染まって形が見える**のはこの項による
        total += mokume_surroundings(surroundings, n) * ambientResponse;

        if (shininess > 0.0) {
            // **反射の向きで読むぶん。** 粗いほど、周囲をぜんぶ混ぜた色へ寄る
            float3 reflected = mix(
                mokume_surroundings(surroundings, reflect(-toEye, n)),
                mokume_surroundingsAverage(surroundings), roughness);
            float nv = max(dot(n, toEye), 1e-4);
            gloss += reflected * (f0 + (1.0 - f0) * pow(1.0 - nv, 5.0));
        }
    }

    // 艶は乗算済みの世界へ入れ直す (半透明の面では、その分だけ薄く乗る)
    return emissive + base * total + gloss * color.a;
}

// 字形を焼いた面の読み取り方。字の縁を滑らかにするため線形に読み、
// 端では外側へはみ出さない
constexpr sampler kGlyphSampler(
    coord::normalized, filter::linear, address::clamp_to_edge);

/// 利用者が渡した面の読み取り方。**組み込みが `texel` を読むのと同じ規則**にしてある —
/// 同じ絵を貼ったのに、断片から読むと縁や滑らかさが違う、が起きない。
constexpr sampler kSurfaceSampler(
    coord::normalized, filter::linear, address::clamp_to_edge);

/// 渡した面から読む。位置は 0…1。
///
/// ```metal
/// float4 paint(Fragment in, Values values, Surfaces surfaces) {
///     return mokume_sample(surfaces.grain, in.uv) * mokume_sample(surfaces.dirt, in.place);
/// }
/// ```
static inline float4 mokume_sample(texture2d<float> surface, float2 spot) {
    return surface.sample(kSurfaceSampler, spot);
}

/// 1 画素ぶんの入力。**利用者の断片が受け取るのはこれだけ。**
struct Fragment {
    /// 面の中の位置 (画素・左上が原点)。
    float2 position;
    /// 面の中の位置を 0…1 で表したもの。
    float2 place;
    /// 読む面の中の、この画素が指す位置 (0…1)。
    float2 uv;
    /// 図形が持っている色 (線形・アルファ乗算済み)。
    float4 color;
    /// 読む面から読んだ値 (線形・アルファ乗算済み)。
    float4 texel;
    /// **形自身の座標**での、この画素が指す位置。立体だけが持つ (平面は 0)。
    ///
    /// 置き場所の変換を通す**前**の座標なので、**形を動かしても回しても変わらない** —
    /// ここから作った模様は形の表面に留まる。単位は形を置いたときの寸法そのままで、
    /// 例えば `box(520, 26, 300)` なら x は −260…260 を取る。
    float3 shapePosition;
    /// 形自身の座標での面の向き (長さ 1)。
    ///
    /// ``shapePosition`` と同じ座標系なので、**回しても面ごとの向きが変わらない**。
    /// 向きを持たない頂点 (立体の線と点) と平面では 0 なので、使う前に長さを見る。
    /// 形から求めた向きは、裏を向いている面では見えている側へ裏返る (光と同じ規則)。
    ///
    /// **面の向きは 3 つの座標で届く**。どれも長さ 1 で、0 になる場所と裏返しの規則は
    /// 3 つとも同じである:
    ///
    /// | 欄 | 座標 | 形を回すと | 視点を動かすと | 使いどころ |
    /// | --- | --- | --- | --- | --- |
    /// | `shapeNormal` | 形自身 | 変わらない | 変わらない | 模様を表面に留める |
    /// | ``worldNormal`` | 世界 | 変わる | 変わらない | 世界の決まった向き (上・光の来る側) と比べる |
    /// | ``viewNormal`` | 視点 | 変わる | 変わる | 見ている側との角度・向きをそのまま色にする |
    float3 shapeNormal;
    /// 世界の座標での面の向き (長さ 1)。**置き場所の変換を通した後**の向きで、光が
    /// 当たるのと同じ向きである。
    ///
    /// 形を回すと変わり、視点を動かしても変わらない。0 になる場所と裏返しの規則は
    /// ``shapeNormal`` と同じ。
    float3 worldNormal;
    /// 視点から見た面の向き (長さ 1)。x が画面の右、y が画面の下、z が手前 (見ている側)
    /// を指す。
    ///
    /// 形を回しても視点を動かしても変わる。p5.js の `normalMaterial()` が色にするのは
    /// この向きで、軸の取り方も同じである (色の値は線形として扱われるので、見え方は
    /// 同じにはならない)。
    /// 何も指定していない視点は面の正面から見ているので、``worldNormal`` と一致する。
    /// 0 になる場所と裏返しの規則は ``shapeNormal`` と同じ。
    float3 viewNormal;
    /// スケッチが始まってからの秒数。
    float time;
    /// 面の大きさ (画素)。
    float2 resolution;
    /// 揺らぎの種。`noiseSeed()` が決めたものがそのまま届く。
    ///
    /// **断片が種を受け取るので、利用者は配線しなくてよい。** `noiseSeed()` を 1 度
    /// 呼べば、CPU で引く `noise()` と断片で引く `mokume_noise()` の両方に効く。
    uint noiseSeed;
    /// 重ねる枚数と、1 枚ごとの弱まり。`noiseDetail()` が決める。
    uint noiseOctaves;
    float noiseFalloff;
    /// 計算が書いた数の並び。`numbers()` で渡したものが届く。
    ///
    /// **渡していなければ 1 個の 0 を指す。** 何も指さない状態にすると、渡し忘れた
    /// 断片が絵の乱れではなく異常終了として出る。範囲は書いた側が知っているので、
    /// ここでは長さを配らない。
    device const float *numbers;
};

// MARK: - 揺らぎ
//
// **Swift の `ValueNoise` と同じ式である。** 同じ種・同じ座標なら、CPU で引いても
// ここで引いても同じ値が出る — 面と立体で同じ模様を出すのに、揺らぎを 2 つ別々に
// 持たなくて済むようにするためである (#366)。
//
// 二重管理を許すのは ADR-0001 原則 9 に反するので、**食い違いは機械が見る** —
// NoiseParityTests が代表点で両者を突き合わせ、ずれたら赤くなる。ここを触ったら
// 向こうも触ることになる。
//
// **傾き (`mokume_noiseGradient`) は断片の側にだけあり、`ValueNoise` に対応するものは
// 無い。** 傾きを要る作品は断片の中でしか使っておらず、CPU で傾きを引く作品はまだ
// 無いので、想定だけの口を先回りで作らない (ADR-0001 原則 4・#1141)。揃えている
// 約束は値のほうで、値の経路はここでも 1 本のままである。傾きがその値の傾きになって
// いることは、NoiseGradientTests が CPU の `noise()` の差分と突き合わせて見る。

/// 格子点の値を作る混ぜ合わせ。**Swift の `ValueNoise.hash` と 1 行ずつ対応する。**
static inline uint mokume_noiseHash(int x, int y, int z, uint seed) {
    uint h = uint(x) * 0x27D4EB2Du;
    h ^= uint(y) * 0x165667B1u;
    h ^= uint(z) * 0x9E3779B1u;
    h ^= seed * 0x85EBCA6Bu;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    h *= 0x297A2D39u;
    h ^= h >> 15;
    return h;
}

/// 格子点の値 (0…1)。**ここまでは整数演算だけ**なので、CPU 側とビット単位で一致する。
static inline float mokume_noiseCorner(int x, int y, int z, uint seed) {
    return float(mokume_noiseHash(x, y, z, seed) >> 8) * (1.0 / 16777216.0);
}

/// 格子を繋いだ 1 枚ぶんの揺らぎ。端で傾きが 0 になる繋ぎ方
/// (折れ目が縞として乗らないようにするため)。
static inline float mokume_noiseLayer(float3 p, uint seed) {
    // **端で切る。** 格子の番号は 32 ビット整数なので、外まで数えると変換が壊れる。
    // Swift 側の `ValueNoise.coordinateLimit` と同じ値で切るので、外に出ても一致する
    float3 c = clamp(p, -1000000.0, 1000000.0);
    float3 i = floor(c);
    float3 f = c - i;
    float3 t = f * f * (3.0 - 2.0 * f);

    int x0 = int(i.x), y0 = int(i.y), z0 = int(i.z);
    int x1 = x0 + 1, y1 = y0 + 1, z1 = z0 + 1;

    float near = mix(
        mix(mokume_noiseCorner(x0, y0, z0, seed), mokume_noiseCorner(x1, y0, z0, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z0, seed), mokume_noiseCorner(x1, y1, z0, seed), t.x),
        t.y);
    float far = mix(
        mix(mokume_noiseCorner(x0, y0, z1, seed), mokume_noiseCorner(x1, y0, z1, seed), t.x),
        mix(mokume_noiseCorner(x0, y1, z1, seed), mokume_noiseCorner(x1, y1, z1, seed), t.x),
        t.y);
    return mix(near, far, t.z);
}

/// その座標の揺らぎ (0…1)。**種と細かさは画素が持っている**ので、渡すのは座標だけ。
///
/// ```metal
/// float4 paint(Fragment in, Values values) {
///     float g = mokume_noise(in, in.place * 8.0);
///     return float4(g, g, g, 1.0);
/// }
/// ```
static inline float mokume_noise(Fragment f, float3 p) {
    float sum = 0.0;
    float total = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    uint octaves = max(f.noiseOctaves, 1u);
    for (uint octave = 0; octave < octaves; octave++) {
        // 枚ごとに種をずらす。ずらさないと、倍率違いの同じ模様が重なって格子の目が見える
        uint layerSeed = f.noiseSeed + octave * 0x9E3779B1u;
        sum += mokume_noiseLayer(p * frequency, layerSeed) * amplitude;
        total += amplitude;
        amplitude *= f.noiseFalloff;
        frequency *= 2.0;
    }
    return total > 0.0 ? sum / total : 0.0;
}

static inline float mokume_noise(Fragment f, float2 p) {
    return mokume_noise(f, float3(p, 0.0));
}

static inline float mokume_noise(Fragment f, float x) {
    return mokume_noise(f, float3(x, 0.0, 0.0));
}

/// 1 枚ぶんの揺らぎ (`mokume_noiseLayer`) の傾き。**同じ格子点を引き、繋ぎの重みを
/// 微分したもの**で、値の側の式は触らずに横へ並べてある。
static inline float3 mokume_noiseLayerGradient(float3 p, uint seed) {
    // 切り方は値と同じ。**端は整数なので、外に張り付いた軸は格子の上に乗り、下の
    // 繋ぎの重みの傾きが 0 になる** — 値が動かない所では傾きも 0 である
    float3 c = clamp(p, -1000000.0, 1000000.0);
    float3 i = floor(c);
    float3 f = c - i;
    float3 t = f * f * (3.0 - 2.0 * f);
    // 繋ぎの重み (3t² − 2t³) の傾き。格子の上 (f = 0, 1) でちょうど 0 になる
    float3 dt = 6.0 * f * (1.0 - f);

    int x0 = int(i.x), y0 = int(i.y), z0 = int(i.z);
    int x1 = x0 + 1, y1 = y0 + 1, z1 = z0 + 1;

    float c000 = mokume_noiseCorner(x0, y0, z0, seed);
    float c100 = mokume_noiseCorner(x1, y0, z0, seed);
    float c010 = mokume_noiseCorner(x0, y1, z0, seed);
    float c110 = mokume_noiseCorner(x1, y1, z0, seed);
    float c001 = mokume_noiseCorner(x0, y0, z1, seed);
    float c101 = mokume_noiseCorner(x1, y0, z1, seed);
    float c011 = mokume_noiseCorner(x0, y1, z1, seed);
    float c111 = mokume_noiseCorner(x1, y1, z1, seed);

    // 軸ごとに、その軸に沿った格子点の差を、残りの 2 軸の重みで混ぜる
    float dx = mix(mix(c100 - c000, c110 - c010, t.y), mix(c101 - c001, c111 - c011, t.y), t.z);
    float dy = mix(mix(c010 - c000, c110 - c100, t.x), mix(c011 - c001, c111 - c101, t.x), t.z);
    float dz = mix(mix(c001 - c000, c101 - c100, t.x), mix(c011 - c010, c111 - c110, t.x), t.y);
    return float3(dx, dy, dz) * dt;
}

/// その座標での揺らぎの傾き — `mokume_noise(f, p)` を p の各軸で微分したもの
/// (∂/∂x, ∂/∂y, ∂/∂z)。渡した座標と同じ次元で返る。
///
/// 隣を引いて差を取るのと違い、**格子の繋ぎ方を閉じた形で微分する**ので、隣り合う
/// 画素で傾きが階段にならない。種・重ねる枚数・弱まりは値と同じものが効き、値と
/// 同じ合計で割る — 返るのは `mokume_noise` が返す値そのものの傾きである。
///
/// ```metal
/// float4 paint(Fragment in, Values values) {
///     // 揺らぎを高さとみた面を、左上からの光で照らす
///     float2 slope = mokume_noiseGradient(in, in.place * 8.0);
///     float3 normal = normalize(float3(-slope * 0.6, 1.0));
///     float lit = max(dot(normal, normalize(float3(-1.0, -1.0, 1.0))), 0.0);
///     return float4(lit, lit, lit, 1.0);
/// }
/// ```
///
/// **傾きは渡した座標あたり**である。上の例なら、面の位置 (`in.place`) あたりの傾きは
/// 返った値の 8 倍になる。値と傾きの両方が要るなら `mokume_noise` と別々に呼ぶ
/// (格子を 2 度引く)。
static inline float3 mokume_noiseGradient(Fragment f, float3 p) {
    // 枚の重ね方 (種のずらし方・弱まり・倍率) は `mokume_noise` と同じ。食い違うと
    // 値の傾きではなくなり、NoiseGradientTests が赤くなる
    float3 sum = 0.0;
    float total = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    uint octaves = max(f.noiseOctaves, 1u);
    for (uint octave = 0; octave < octaves; octave++) {
        uint layerSeed = f.noiseSeed + octave * 0x9E3779B1u;
        // 倍率を掛けた座標で引いているので、傾きにも倍率が掛かる
        sum += mokume_noiseLayerGradient(p * frequency, layerSeed) * (amplitude * frequency);
        total += amplitude;
        amplitude *= f.noiseFalloff;
        frequency *= 2.0;
    }
    return total > 0.0 ? sum / total : float3(0.0);
}

static inline float2 mokume_noiseGradient(Fragment f, float2 p) {
    return mokume_noiseGradient(f, float3(p, 0.0)).xy;
}

static inline float mokume_noiseGradient(Fragment f, float x) {
    return mokume_noiseGradient(f, float3(x, 0.0, 0.0)).x;
}

/// 出した色を下地と混ぜる。**通るのは 8 種だけ** (`kAdd` … `kScreen`)。
///
/// **`kBlend` (0) と `kReplace` (9) はここへ来ない。** 前者は乗算済みの source-over で
/// 固定機能のブレンドと式が一致し、後者は下地を見ない — どちらも下地を読まない断片
/// (`mokume_fragmentDirect` / `mokume_formFragmentBlend` / `mokume_formFragmentReplace`) で
/// 描かれる ([#758])。**どの混ぜ方がどちらの経路へ行くかの一覧は
/// `ShapePipeline.BlendStates` の doc が持つ** ([#887])。
///
/// **式は W3C の合成の一般式である** ([Compositing and Blending Level 1] の 6 節・10 節)。
/// 大文字は乗算前、小文字は乗算済みの色で、`B` が混ぜ方ごとの式:
///
/// ```text
/// 置く色  Cs' = (1 − αb)·Cs + αb·B(Cb, Cs)
/// 結果    co  = mix(cb, Cs', αs)
///         αo  = αb + αs·(1 − αb)          (乗算済みの source-over)
/// ```
///
/// 混ぜる相手 (下地) がどれだけ居るかを**下地のアルファ**が、置いた色をどれだけ効かせるかを
/// **上のアルファ**が決める。だから次の 3 つが、どのモードでも揃って成り立つ:
///
/// - **アルファ 0 の色は下地を変えない** (αs = 0 なら `co = cb`)
/// - **下地が透明な所では、置いた色がそのまま載る** (αb = 0 なら `Cs' = Cs` で、source-over
///   と同じになる)。以前は下地のアルファを見ず、透明な下地を「黒」と読んで混ぜていたので、
///   `multiply` は黒い形を、`subtract` は負の色を置いていた ([#1447])
/// - **不透明な下地の上では、以前の式と同じ値を計算する** (αb = 1 なら `Cs' = B` で、
///   `mix(Cb, B, αs)` に戻る)。不透明な下地に描いた絵は動かない
///
/// `add` / `subtract` は W3C に無いが、同じ式を当てる。`add` は `cs + cb` (乗算済みの和)、
/// `subtract` は `cs·(1 − 2αb) + cb` になる。
///
/// [#758]: https://github.com/mokume-metal/mokume/issues/758
/// [#887]: https://github.com/mokume-metal/mokume/issues/887
/// [#1447]: https://github.com/mokume-metal/mokume/issues/1447
/// [Compositing and Blending Level 1]: https://www.w3.org/TR/compositing-1/#generalformula
static inline float4 mokume_composite(float4 source, float4 destination, uint mode) {
    // 「色そのもの」どうしを混ぜるので、両方の乗算を戻してから計算する。
    // 乗算済みのまま混ぜると、半透明の色が暗い色として扱われてしまう
    float3 s = straighten(source);
    float3 d = straighten(destination);
    float3 mixed;

    switch (mode) {
        case kAdd: mixed = s + d; break;
        case kSubtract: mixed = d - s; break;
        case kLightest: mixed = max(s, d); break;
        case kDarkest: mixed = min(s, d); break;
        case kDifference: mixed = abs(d - s); break;
        case kExclusion: mixed = s + d - 2.0 * s * d; break;
        case kMultiply: mixed = s * d; break;
        case kScreen: mixed = s + d - s * d; break;
        // **来ない番号を、無害な側で飲む。** 上の doc のとおり 0 と 9 は別の列へ行くので
        // 届く経路が無い。以前は `s` だったので、万一届いたら置き換え相当で下地を消していた
        // (#887)。**下地そのものを返す** — `mixed = d` で下の式へ流すと、透ける下地の上では
        // 置く色に上の色が混ざるので、下地は保たれない (#1447)
        default: return destination;
    }

    // **飽和させない。** 作業空間は範囲外の値 (負値および 1.0 超) を捨てず、表示できる
    // 範囲へ畳むのは出力段だけである — 規範は「線形で計算し、境界で変換する」で、
    // 境界は入口と出口の 2 箇所しかない (ADR-0011 決定 1・決定 3)。ここは出口ではない。
    //
    // かつてこの位置に `clamp(mixed, 0.0, 1.0)` があり、`.add` が 1 描画ごとに 1.0 で
    // 頭打ちになって光を積み上げられなかった (#1057)。切っていたのは 8 種だけなので、
    // 固定機能の列へ移った `.blend` は最初から 1.0 超を保っていた (#758)。
    //
    // **`.subtract` の暗部が 0 へ落ちるのは、この決定に含まれる。** 不透明な下地の上では
    // 式が `d - a*s` へ単純化し、以前の「0 で折れる」非線形が消えるためで、退行ではない。

    // **混ぜる相手がどれだけ居るかは、下地のアルファが決める。** 透明な所では上の色そのもの
    // を、不透明な所では混ぜた色を置く。`mix(s, mixed, αb)` と書かないのは、αb = 1 で
    // `mixed` が丸めなしに出るようにするため — `s + (mixed − s)·1` は浮動小数では `mixed`
    // に戻るとは限らない。こう書けば、不透明な下地の上では以前の式と同じ値を計算する
    // (8 bit の台帳に出る幅ではないが、どちらでも動かないなら丸めの無いほうを採る)
    float3 placed = (1.0 - destination.a) * s + destination.a * mixed;

    // **どれだけ効かせるかは上のアルファが決める。** これを全モードで揃えるので、
    // アルファ 0 の色はどのモードでも下地を変えない。**下地は乗算済みのまま混ぜる** —
    // 結果もそのまま乗算済みになり、戻した色を掛け直す往復が要らない
    float3 result = mix(destination.rgb, placed, source.a);
    float outAlpha = destination.a + source.a * (1.0 - destination.a);
    return float4(result, outAlpha);
}

/// 画素の色を出す。**組み込みも利用者の断片も、書くのはこれ 1 本。**
///
/// **面を宣言した断片だけ、受け取るものが 1 つ増える。** 宣言していない断片は今までの
/// 2 引数のままで、組み上がる原稿も 1 バイト変わらない ([#407])。
///
/// [#407]: https://github.com/mokume-metal/mokume/issues/407
#ifdef MOKUME_SURFACES
float4 paint(Fragment in, Values values, Surfaces surfaces);
#else
float4 paint(Fragment in, Values values);
#endif

// 入口が束ねるものの一覧。**入口は 2 つあるが、束ね方は 1 つしかない。**
//
// 下地を読む入口と読まない入口 (`mokume_fragmentMain` / `mokume_fragmentDirect`) は、
// 束ねる口が 1 つでも食い違うと**絵が壊れたまま組み上がる** — 番号は Swift 側
// (`ShapePipeline`) と合っていればよく (`ShaderInterfaceTests` が反射で突き合わせる)、
// 2 つの入口が互いに合っている必要はコンパイラには分からない。だから並びを写さず、
// 1 つの綴りを両方が使う。
#ifdef MOKUME_SURFACES
// 利用者が宣言した面。**口の数は宣言した枚数によらず固定**で、余りには
// 別の面が束ねてある (何も束ねない口を作らないため)
#define MOKUME_SURFACE_PARAMS \
    texture2d<float> user_surface_0 [[texture(2)]], \
    texture2d<float> user_surface_1 [[texture(3)]], \
    texture2d<float> user_surface_2 [[texture(4)]], \
    texture2d<float> user_surface_3 [[texture(5)]],
#define MOKUME_SURFACE_ARGS \
    , mokume_surfaces(user_surface_0, user_surface_1, user_surface_2, user_surface_3)
#else
#define MOKUME_SURFACE_PARAMS
#define MOKUME_SURFACE_ARGS
#endif

#define MOKUME_SHAPE_PARAMS \
    ShapeFragmentIn in [[stage_in]], \
    constant Uniforms &uniforms [[buffer(4)]], \
    constant Values &values [[buffer(5)]], \
    constant Lighting &lighting [[buffer(6)]], \
    constant Light *lights [[buffer(7)]], \
    constant Material &material [[buffer(8)]], \
    constant Surroundings &surroundings [[buffer(9)]], \
    device const float *numbers [[buffer(11)]], \
    texture2d<float> source_texture [[texture(0)]], \
    depth2d<float> shadow_texture [[texture(1)]], \
    bool isFrontFacing [[front_facing]]

#define MOKUME_SHAPE_ARGS \
    in, uniforms, values, lighting, lights, material, surroundings, numbers, \
    source_texture, shadow_texture, isFrontFacing

/// この画素が出す色。**下地は見ない。**
///
/// 下地との混ぜ方は呼ぶ側が決める — 固定機能のブレンドへ渡す入口と、自分で混ぜる
/// 入口があるので、色を出す仕事はここ 1 本にする。
static inline float4 mokume_shapeColor(
    ShapeFragmentIn in,
    constant Uniforms &uniforms,
    constant Values &values,
    constant Lighting &lighting,
    constant Light *lights,
    constant Material &material,
    constant Surroundings &surroundings,
    device const float *numbers,
    texture2d<float> source_texture,
    depth2d<float> shadow_texture,
    bool isFrontFacing
#ifdef MOKUME_SURFACES
    , Surfaces surfaces
#endif
) {
    // **形から求めた向きだけは、どちらの側から見ても光を受ける。** 裏を向いている面
    // では向きを裏返す — 利用者が頂点を並べる向き (巻き方) で絵が真っ黒になるのを
    // 避けるため。書かれた向きは裏返さない (書いた指定を黙って覆さない)。
    // **判定は光と断片で 1 つ**にする — 分けると、光が当たっている側と断片が向きだと
    // 思っている側が食い違う面が作れてしまう
    bool isBackOfDerived = in.isDerivedNormal > 0.5 && !isFrontFacing;
    // 光と断片の 3 つの向きは、この 1 本から作る
    float3 normal = isBackOfDerived ? -in.normal : in.normal;

    Fragment f;
    f.position = in.position.xy;
    f.place = in.position.xy / uniforms.resolution;
    f.uv = in.uv;
    f.color = in.color;
    // **周囲そのものを出す列は、光も材質も見ない。** 見ている向きへ周囲を読むだけで、
    // 背景と映り込みが同じ 1 本の関数から出る
    if (surroundings.horizonAndBackdrop.w > 0.5) {
        float3 toEye = lighting.viewer.w > 0.5
            ? normalize(lighting.viewer.xyz - in.worldPosition)
            : normalize(lighting.viewer.xyz);
        f.color = float4(mokume_surroundings(surroundings, -toEye), 1.0);
    }
    // 光も周囲も無ければ、色はそのまま (手本と同じ = 平坦な塗り)。**周囲だけを
    // 置いても効く** — 置いたのに何も起きない設定を作らないためで、周囲は光と同じく
    // 面を明るくするものである。
    // **向きを持たない頂点も色そのまま** — 立体の線と点がこれに当たる (平面の輪郭が
    // 光を受けないのと同じ扱い)
    else if (
        (lighting.count > 0 || surroundings.topAndPresence.w > 0.5)
        && dot(in.normal, in.normal) > 0.0)
    {
        float3 lit = mokume_shade(
            lights, lighting.offset, lighting.count, in.worldPosition, normal,
            lighting.viewer, in.color, material, surroundings, shadow_texture, uniforms);
        f.color = float4(lit, in.color.a);
    }
    f.texel = source_texture.sample(kGlyphSampler, in.uv);
    f.shapePosition = in.shapePosition;
    // **長さがあるときだけ揃える。** 向きを持たない頂点 (立体の線と点) と平面は 0 で、
    // そのまま正規化すると 0 が数でない値に化ける
    float3 shapeNormal = isBackOfDerived ? -in.shapeNormal : in.shapeNormal;
    f.shapeNormal = dot(shapeNormal, shapeNormal) > 0.0 ? normalize(shapeNormal) : float3(0.0);
    // 置き場所の向きの行列は拡大を含みうるので、世界の向きも揃え直す。視点の行列は
    // 回すだけなので、揃えた向きを移せば長さ 1 のまま (0 は 0 のまま) である
    f.worldNormal = dot(normal, normal) > 0.0 ? normalize(normal) : float3(0.0);
    f.viewNormal = float3x3(lighting.view[0].xyz, lighting.view[1].xyz, lighting.view[2].xyz)
        * f.worldNormal;
    f.time = uniforms.time;
    f.resolution = uniforms.resolution;
    f.noiseSeed = uniforms.noiseSeed;
    f.noiseOctaves = uniforms.noiseOctaves;
    f.noiseFalloff = uniforms.noiseFalloff;
    f.numbers = numbers;

#ifdef MOKUME_SURFACES
    return paint(f, values, surfaces);
#else
    return paint(f, values);
#endif
}

/// 画素を描く入口。**下地を読み、混ぜ方で分岐する。**
///
/// 使うのは固定機能のブレンドで表せない混ぜ方の列だけである
/// (一覧は `ShapePipeline.BlendStates` の doc)。
fragment float4 mokume_fragmentMain(
    MOKUME_SURFACE_PARAMS
    MOKUME_SHAPE_PARAMS,
    constant uint &mode [[buffer(2)]],
    float4 destination [[color(0)]])
{
    return mokume_composite(
        mokume_shapeColor(MOKUME_SHAPE_ARGS MOKUME_SURFACE_ARGS), destination, mode);
}

/// 画素を描く入口。**下地を読まない。**
///
/// 重ねる (`.blend`) 列と置き換える (`.replace`) 列が使う。前者は乗算済みの
/// source-over なので固定機能のブレンドが同じ式で混ぜ、後者は下地を見ない —
/// どちらも断片が下地を読む必要が無い ([#758])。
///
/// **出す色は入口によらず同じ**である (`mokume_shapeColor` が 1 本)。
///
/// [#758]: https://github.com/mokume-metal/mokume/issues/758
fragment float4 mokume_fragmentDirect(
    MOKUME_SURFACE_PARAMS
    MOKUME_SHAPE_PARAMS)
{
    return mokume_shapeColor(MOKUME_SHAPE_ARGS MOKUME_SURFACE_ARGS);
}
