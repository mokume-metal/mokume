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

/// この列に効く光が、置き場のどこから何個あるか。
struct Lighting {
    uint offset;
    uint count;
};

/// 面が受け取る光を合計する。
///
/// **光を 1 つも置いていなければ、面はそのままの色で出る** (合計を返さず、呼ぶ側が
/// 数で分岐する)。環境光は向きを持たないのでそのまま足し、向きを持つ光は面の向きと
/// のなす角で減る (拡散のみ。粗さや金属らしさは材質の担当)。
static inline float3 mokume_gatherLight(
    constant Light *lights, uint offset, uint count,
    float3 worldPosition, float3 normal)
{
    float3 total = float3(0.0);
    float3 n = normalize(normal);
    for (uint index = 0; index < count; index++) {
        constant Light &light = lights[offset + index];
        uint kind = uint(light.colorAndKind.w);
        float3 color = light.colorAndKind.rgb;

        if (kind == kAmbientLight) {
            total += color;
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

        total += color * max(dot(n, toLight), 0.0) * cone;
    }
    return total;
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

/// フレームを通して変わらない値。
struct Uniforms {
    float time;
    float2 resolution;
};

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
};

/// アルファの乗算を戻す。完全に透明な画素には戻すべき色が無いので 0 を返す。
static inline float3 straighten(float4 color) {
    return color.a > 0.0 ? color.rgb / color.a : float3(0.0);
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
    texture2d<float> source_texture [[texture(0)]],
    bool isFrontFacing [[front_facing]],
    float4 destination [[color(0)]])
{
    Fragment f;
    f.position = in.position.xy;
    f.place = in.position.xy / uniforms.resolution;
    f.uv = in.uv;
    f.color = in.color;
    // 光が 1 つも置かれていなければ、色はそのまま (手本と同じ = 平坦な塗り)。
    // **向きを持たない頂点も色そのまま** — 立体の線と点がこれに当たる (平面の輪郭が
    // 光を受けないのと同じ扱い)
    if (lighting.count > 0 && dot(in.normal, in.normal) > 0.0) {
        // **形から求めた向きだけは、どちらの側から見ても光を受ける。** 裏を向いている
        // 面では向きを裏返す — 利用者が頂点を並べる向き (巻き方) で絵が真っ黒になるのを
        // 避けるため。書かれた向きは裏返さない (書いた指定を黙って覆さない)
        float3 normal = in.normal;
        if (in.isDerivedNormal > 0.5 && !isFrontFacing) { normal = -normal; }
        float3 received = mokume_gatherLight(
            lights, lighting.offset, lighting.count, in.worldPosition, normal);
        f.color = float4(in.color.rgb * received, in.color.a);
    }
    f.texel = source_texture.sample(kGlyphSampler, in.uv);
    f.textureKind = textureKind;
    f.time = uniforms.time;
    f.resolution = uniforms.resolution;

    return mokume_composite(paint(f, values), destination, mode);
}
