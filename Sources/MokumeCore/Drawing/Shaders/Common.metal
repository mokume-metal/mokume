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

/// この列を描く材質。並びは Swift 側の `PackedMaterial` と一致する。
struct Material {
    /// 周りの光への返し (rgb) と、艶の鋭さ (w)。
    float4 ambientAndShininess;
    /// 自発光 (rgb) と、金属らしさ (w)。
    float4 emissiveAndMetalness;
};

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
///        + 艶
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
    float4 color, Material material)
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
        float3 lit = mokume_shade(
            lights, lighting.offset, lighting.count, in.worldPosition, normal,
            lighting.viewer, in.color, material);
        f.color = float4(lit, in.color.a);
    }
    f.texel = source_texture.sample(kGlyphSampler, in.uv);
    f.textureKind = textureKind;
    f.time = uniforms.time;
    f.resolution = uniforms.resolution;

    return mokume_composite(paint(f, values), destination, mode);
}
