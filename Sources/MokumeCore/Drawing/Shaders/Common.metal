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

// 光の種類。Light.Kind と対応する
constant uint kAmbientLight = 0;
constant uint kDirectionalLight = 1;
constant uint kPointLight = 2;
constant uint kSpotLight = 3;

/// この列に効く光が、置き場のどこから何個あるか。と、どこから見ているか。
struct Lighting {
    uint offset;
    uint count;
    /// 16 バイト境界へ揃えるための詰め物 (Swift 側もこの位置を空けている)。
    float2 padding;
    /// 見ている場所。`w` が 1 なら xyz は**視点の位置** (透視)、0 なら
    /// xyz は**見ている側へ向かう一定の向き** (平行)。艶は見る向きで変わるので要る。
    float4 viewer;
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

/// フレームを通して変わらない値。
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

/// 焼き付けた影の読み方。**奥行きを数として比べる**ので、混ぜずにそのまま読む
/// (混ぜると、比べる相手が「どこにも無い奥行き」になって縁が濁る)。
constexpr sampler kShadowSampler(
    coord::normalized, filter::nearest, address::clamp_to_edge);

/// その点が光から見えているか (1 = 見えている, 0 = 遮られている)。
///
/// **焼いた範囲の外は遮らない。** 範囲は作品が決めるものなので、外側を「影」に
/// すると、範囲を小さくしただけで世界の端が黒く沈む。
static inline float mokume_shadowFactor(
    texture2d<float> baked, float4x4 lightMatrix, float texel, float bias,
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

    // 近くの 9 点を数えて、縁を少しなめらかにする
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float recorded = baked.sample(kShadowSampler, uv + float2(x, y) * texel).r;
            lit += limit <= recorded ? 1.0 : 0.0;
        }
    }
    return lit / 9.0;
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
    texture2d<float> baked, constant Uniforms &uniforms)
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
            float peak = nh * nh * (spread2 - 1.0) + 1.0;
            float distribution = spread2 / max(M_PI_F * peak * peak, 1e-6);
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

// 面の中身の種類。TextureKind と対応する
constant uint kCoverage = 0;

// 混ぜ方の番号は BlendMode.rawIndex と対応する。ここを増やしたら向こうも増やす。
constant uint kBlend = 0;
constant uint kAdd = 1;
constant uint kSubtract = 2;
constant uint kLightest = 3;
constant uint kDarkest = 4;
constant uint kDifference = 5;
constant uint kExclusion = 6;
constant uint kMultiply = 7;
constant uint kScreen = 8;
constant uint kReplace = 9;

// 字形を焼いた面の読み取り方。字の縁を滑らかにするため線形に読み、
// 端では外側へはみ出さない
constexpr sampler kGlyphSampler(
    coord::normalized, filter::linear, address::clamp_to_edge);

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
    /// 読む面から読んだ値。
    float4 texel;
    /// 読む面の中身の種類。`kCoverage` なら覆っている割合。
    uint textureKind;
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

/// 出した色を下地と混ぜる。
static inline float4 mokume_composite(float4 source, float4 destination, uint mode) {
    // 置き換えるモードだけは下地を見ない
    if (mode == kReplace) {
        return source;
    }

    // 重ねるモードは、乗算済みのまま素直に足せる
    if (mode == kBlend) {
        return source + destination * (1.0 - source.a);
    }

    // 以降は「色そのもの」どうしを混ぜるので、両方の乗算を戻してから計算する。
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
        default: mixed = s; break;
    }

    // 結果として出す値は飽和させる。作業空間は範囲外を許すが、
    // ここで抑えないと混ぜた結果が下地を壊す
    mixed = clamp(mixed, 0.0, 1.0);

    // **どれだけ効かせるかはアルファが決める。** これを全モードで揃えるので、
    // アルファ 0 の色はどのモードでも下地を変えない
    float3 result = mix(d, mixed, source.a);
    float outAlpha = destination.a + source.a * (1.0 - destination.a);
    return float4(result * outAlpha, outAlpha);
}

/// 画素の色を出す。**組み込みも利用者の断片も、書くのはこれ 1 本。**
float4 paint(Fragment in, Values values);

fragment float4 mokume_fragmentMain(
    ShapeFragmentIn in [[stage_in]],
    constant uint &mode [[buffer(2)]],
    constant uint &textureKind [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    constant Values &values [[buffer(5)]],
    constant Lighting &lighting [[buffer(6)]],
    constant Light *lights [[buffer(7)]],
    constant Material &material [[buffer(8)]],
    constant Surroundings &surroundings [[buffer(9)]],
    texture2d<float> source_texture [[texture(0)]],
    texture2d<float> shadow_texture [[texture(1)]],
    bool isFrontFacing [[front_facing]],
    float4 destination [[color(0)]])
{
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
        // **形から求めた向きだけは、どちらの側から見ても光を受ける。** 裏を向いている
        // 面では向きを裏返す — 利用者が頂点を並べる向き (巻き方) で絵が真っ黒になるのを
        // 避けるため。書かれた向きは裏返さない (書いた指定を黙って覆さない)
        float3 normal = in.normal;
        if (in.isDerivedNormal > 0.5 && !isFrontFacing) { normal = -normal; }
        float3 lit = mokume_shade(
            lights, lighting.offset, lighting.count, in.worldPosition, normal,
            lighting.viewer, in.color, material, surroundings, shadow_texture, uniforms);
        f.color = float4(lit, in.color.a);
    }
    f.texel = source_texture.sample(kGlyphSampler, in.uv);
    f.textureKind = textureKind;
    f.time = uniforms.time;
    f.resolution = uniforms.resolution;
    f.noiseSeed = uniforms.noiseSeed;
    f.noiseOctaves = uniforms.noiseOctaves;
    f.noiseFalloff = uniforms.noiseFalloff;

    return mokume_composite(paint(f, values), destination, mode);
}
