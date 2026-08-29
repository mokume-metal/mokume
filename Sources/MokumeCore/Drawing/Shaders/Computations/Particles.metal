// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 粒を 1 フレーム進め、描画へ渡す置き場所を書く。
//
// **この置き場にある断片は計算の前置き (Compute.metal) を付けて組み立てる。** 塗りの
// 前置き (Common.metal) を付ける Shaders/ 直下とは組み立て方が違うので、置き場で
// 分けてある (scripts/check-shaders.sh が同じ規則で確かめる)。
//
// 束ねる先の番号は呼ぶ側が決める — Canvas+Particles.swift が
// reads: [指定] / writes: [状態, 置き場所] の順で渡すので、そのまま 0, 1, 2 になる。
//
// **毎フレームの数値も「指定」の置き場から読む** (Values を使わない)。使うと、
// 値を渡さない形で組み立てたときにコンパイルが通らなくなり、ビルド時のシェーダ検査
// (scripts/check-shaders.sh) から外れてしまう。並びは Particles.swift が正本:
//
//   [0…15]  いまの変換 (4x4)
//   [16]    1 フレームの長さ (秒)
//   [17]    フレーム番号
//   [18]    効かせる力の数
//   [19]    予備
//   [20…]   力 (1 つ 8 個)

/// 粒 1 つぶんの状態。**Swift 側の `Particle` と一致していなければならない。**
///
/// ずれても例外は出ず、絵が「それらしく」壊れるだけなので、下の
/// `mokume_particleLayout` が**この宣言のまま**既知の値を書き、CPU 側が読み比べる。
struct Particle {
    float x;
    float y;
    float z;
    float vx;
    float vy;
    float vz;
    float life;
    float span;
    float size;
    float red;
    float green;
    float blue;
    float alpha;
    float seed;
};

/// 同じ形を置く 1 か所ぶん。**Swift 側の `SolidInstance` と一致していなければならない。**
struct SolidInstance {
    float4x4 matrix;
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 color;
};

/// 粒ごと・フレームごとに決まる 0…1 の値。
///
/// **時計から作らない。** 番号から作るので、同じ入力からは何度走らせても同じ列が出る。
static inline float mokume_particleDrift(uint id, uint frame, uint channel) {
    uint h = id * 747796405u + frame * 2891336453u + channel * 2654435761u;
    h ^= h >> 15;
    h *= 2246822519u;
    h ^= h >> 13;
    h *= 3266489917u;
    h ^= h >> 16;
    return float(h & 0xffffffu) / 16777215.0;
}

kernel void mokume_particles(
    device const float *parameters [[buffer(0)]],
    device Particle *particles [[buffer(1)]],
    device SolidInstance *instances [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    Particle p = particles[id];
    float step = parameters[16];

    if (p.life > 0.0) {
        float3 position = float3(p.x, p.y, p.z);
        float3 velocity = float3(p.vx, p.vy, p.vz);
        float3 push = float3(0.0);
        uint frame = uint(max(parameters[17], 0.0));
        uint salt = id + uint(p.seed * 65535.0);
        int count = int(parameters[18]);

        // **渡された順に効く。** 足し合わせるだけなので順序で結果は変わらないが、
        // 減速 (velocity を読む) だけは順序が効く
        for (int i = 0; i < count; i++) {
            const device float *f = parameters + 20 + i * 8;
            int kind = int(f[0]);
            if (kind == 0) {
                push += float3(f[1], f[2], f[3]);
            } else if (kind == 1) {
                float3 toward = float3(f[1], f[2], f[3]) - position;
                push += toward / max(length(toward), 1e-4) * f[4];
            } else if (kind == 2) {
                float3 drift = float3(
                    mokume_particleDrift(salt, frame, 0),
                    mokume_particleDrift(salt, frame, 1),
                    mokume_particleDrift(salt, frame, 2)) * 2.0 - 1.0;
                push += drift * f[4];
            } else if (kind == 3) {
                float2 away = position.xy - float2(f[1], f[2]);
                push += float3(-away.y, away.x, 0.0) / max(length(away), 1e-4) * f[4];
            } else if (kind == 4) {
                push -= velocity * f[4];
            }
        }

        velocity += push * step;
        position += velocity * step;
        p.x = position.x;
        p.y = position.y;
        p.z = position.z;
        p.vx = velocity.x;
        p.vy = velocity.y;
        p.vz = velocity.z;
        p.life = max(p.life - step, 0.0);
        particles[id] = p;
    }

    // いまの変換。**置き場所の先頭 16 個**に置かれている
    float4x4 world = float4x4(
        float4(parameters[0], parameters[1], parameters[2], parameters[3]),
        float4(parameters[4], parameters[5], parameters[6], parameters[7]),
        float4(parameters[8], parameters[9], parameters[10], parameters[11]),
        float4(parameters[12], parameters[13], parameters[14], parameters[15]));

    // **死んだ粒は面積 0 に畳む。** 描く個数を GPU 側で決める仕組みを持たない代わりに、
    // 出ない粒を出ない形にする — 畳まれた三角形は 1 画素も塗らない
    float extent = p.life > 0.0 ? p.size : 0.0;
    float4x4 local = float4x4(
        float4(extent, 0.0, 0.0, 0.0),
        float4(0.0, extent, 0.0, 0.0),
        float4(0.0, 0.0, extent, 0.0),
        float4(p.x, p.y, p.z, 1.0));

    SolidInstance placed;
    placed.matrix = world * local;
    placed.normal0 = float4(1.0, 0.0, 0.0, 0.0);
    placed.normal1 = float4(0.0, 1.0, 0.0, 0.0);
    placed.normal2 = float4(0.0, 0.0, 1.0, 0.0);
    placed.color = float4(p.red, p.green, p.blue, p.alpha);
    instances[id] = placed;
}

/// 自分が見ている配置を書き出す。**検査だけが呼ぶ。**
///
/// 大きさを両側に手で書いて突き合わせる形では、**両方が同時にずれたときに黙って通る**。
/// ここは項目に 1…14 を名前で入れて 2 つ並べて書くので、順序が入れ替わっても・項目が
/// 増減しても・間隔が違っても、CPU 側が読んだ数の並びが合わなくなる。
kernel void mokume_particleLayout(
    device Particle *particles [[buffer(0)]],
    device SolidInstance *instances [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    Particle p;
    p.x = 1.0;
    p.y = 2.0;
    p.z = 3.0;
    p.vx = 4.0;
    p.vy = 5.0;
    p.vz = 6.0;
    p.life = 7.0;
    p.span = 8.0;
    p.size = 9.0;
    p.red = 10.0;
    p.green = 11.0;
    p.blue = 12.0;
    p.alpha = 13.0;
    p.seed = 14.0;
    particles[0] = p;
    // 2 つめは先頭だけ変える。**間隔がずれれば、この値の居場所がずれる**
    p.x = 101.0;
    particles[1] = p;

    SolidInstance s;
    s.matrix = float4x4(
        float4(0.0, 1.0, 2.0, 3.0),
        float4(4.0, 5.0, 6.0, 7.0),
        float4(8.0, 9.0, 10.0, 11.0),
        float4(12.0, 13.0, 14.0, 15.0));
    s.normal0 = float4(16.0, 17.0, 18.0, 19.0);
    s.normal1 = float4(20.0, 21.0, 22.0, 23.0);
    s.normal2 = float4(24.0, 25.0, 26.0, 27.0);
    s.color = float4(28.0, 29.0, 30.0, 31.0);
    instances[0] = s;
    s.matrix[0][0] = 100.0;
    instances[1] = s;
}
