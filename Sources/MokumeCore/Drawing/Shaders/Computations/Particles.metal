// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 粒を 1 フレーム進め、生きている粒だけを詰めて描画へ渡す。
//
// **この置き場にある断片は計算の前置き (Compute.metal) を付けて組み立てる。** 塗りの
// 前置き (Common.metal) を付ける Shaders/ 直下とは組み立て方が違うので、置き場で
// 分けてある (scripts/check-shaders.sh が同じ規則で確かめる)。
//
// ## 3 つの入口で 1 フレーム
//
// 描く個数は GPU が決める (indirect draw)。死んだ粒の枠を頂点段に通さないためで、
// 詰める順序は**枠の番号順**に固定する — 半透明の粒が奥行きつきで描かれるので、
// 重なり順が動けば絵が動く。atomic で数えると順序が走らせるたびに変わるので使わず、
// 並列スキャン (prefix sum) で「自分より前に生き残る粒の数」を求める。スキャンの結果は
// 実行順に依らず一意なので、同じ入力からは同じ絵が出る (ADR-0025 の水準 3)。
//
//   1. mokume_particleFlags  粒ごとに「この 1 フレームを生き残るか」を 0 / 1 で書く
//   2. mokume_particleScan   256 個ずつの区画で exclusive scan を in place に行い、区画の
//                            合計を次の段へ書く。段の数は呼ぶ側が容量から決める
//   3. mokume_particles      状態を進め、生き残る粒だけ各段の値の和の位置へ置き場所を
//                            書く。先頭の thread が描く引数 (個数) を書く
//
// 束ねる先の番号は呼ぶ側が決める — Canvas+Particles.swift が reads / writes の順で
// 渡すので、入口ごとの並びは各 kernel の冒頭に書いてある。
//
// **毎フレームの数値も「指定」の置き場から読む** (Values を使わない)。使うと、
// 値を渡さない形で組み立てたときにコンパイルが通らなくなり、ビルド時のシェーダ検査
// (scripts/check-shaders.sh) から外れてしまう。並びは Particles.swift が正本:
//
//   [0…15]  いまの変換 (4x4)
//   [16]    1 フレームの長さ (秒)
//   [17]    フレーム番号
//   [18]    効かせる力の数
//   [19]    スキャンの段の数 L (uint のビット列)
//   [20]    描く頂点の頭 (uint のビット列)
//   [21]    描く頂点の数 (uint のビット列)
//   [22…26] 段 0…4 の置き場の頭 (uint のビット列)。段 L が生存数 1 個ぶん
//   [27…31] 予備
//   [32…]   力 (1 つ 8 個)

/// スキャンの区画の大きさ。**Swift 側の `Particles.scanBlock` と一致していなければならない。**
/// 一致は `mokume_particleLayout` が書き出し、CPU 側が読み比べる。
#define MOKUME_PARTICLE_BLOCK 256u

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

/// 描く引数。**Metal の `MTLDrawPrimitivesIndirectArguments` と一致していなければならない。**
struct DrawArguments {
    uint vertexCount;
    uint instanceCount;
    uint vertexStart;
    uint baseInstance;
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

/// この 1 フレームを進めたあとも生きているか。
///
/// **旗を立てる側と置き場所を書く側が、同じ式で同じ入力から判定する。** 2 か所に
/// 別々の式を書くと、丸めの違いで「数えたが置かなかった」粒が生まれ、詰めた並びの
/// 末尾に前のフレームの置き場所が残る。
static inline bool mokume_particleSurvives(float life, float step) {
    return life > 0.0 && max(life - step, 0.0) > 0.0;
}

/// 1. 生き残る粒に旗を立てる。
///
///   buffer(0) 指定 (読む) / buffer(1) 状態 (読む) / buffer(2) 段の置き場 (書く)
kernel void mokume_particleFlags(
    device const float *parameters [[buffer(0)]],
    device const Particle *particles [[buffer(1)]],
    device uint *levels [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    float step = parameters[16];
    uint base = as_type<uint>(parameters[22]);
    levels[base + id] = mokume_particleSurvives(particles[id].life, step) ? 1u : 0u;
}

/// 2. 1 段ぶんの exclusive scan。区画 1 つを thread 1 つが順に足す。
///
/// thread 1 つが 256 個を順に読むのは、**threadgroup の組み方に依らない**ためである。
/// simdgroup の幅や threadgroup の大きさを前提にすると、計算の段が組み方を変えた日に
/// 黙って壊れる。区画の合計を次の段へ書くので、段を重ねれば何個でも数えられる。
///
///   buffer(0) 段の頭 [長さ, 読む段の置き場の頭, 書く段の置き場の頭] (uint のビット列・読む)
///   buffer(1) 段の置き場 (読んで書く)
kernel void mokume_particleScan(
    device const float *header [[buffer(0)]],
    device uint *levels [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    uint length = as_type<uint>(header[0]);
    uint from = as_type<uint>(header[1]);
    uint to = as_type<uint>(header[2]);
    uint start = id * MOKUME_PARTICLE_BLOCK;
    uint end = min(start + MOKUME_PARTICLE_BLOCK, length);
    uint running = 0;
    for (uint i = start; i < end; i++) {
        uint value = levels[from + i];
        levels[from + i] = running;
        running += value;
    }
    levels[to + id] = running;
}

/// 3. 粒を進め、生き残る粒だけを詰めて置く。
///
///   buffer(0) 指定 (読む) / buffer(1) 段の置き場 (読む) /
///   buffer(2) 状態 (書く) / buffer(3) 置き場所 (書く) / buffer(4) 描く引数 (書く)
kernel void mokume_particles(
    device const float *parameters [[buffer(0)]],
    device const uint *levels [[buffer(1)]],
    device Particle *particles [[buffer(2)]],
    device SolidInstance *instances [[buffer(3)]],
    device DrawArguments *arguments [[buffer(4)]],
    uint id [[thread_position_in_grid]])
{
    Particle p = particles[id];
    float step = parameters[16];
    uint levelCount = as_type<uint>(parameters[19]);
    // **進める前の寿命で判定する。** 旗を立てた側が見たのと同じ値である
    bool survives = mokume_particleSurvives(p.life, step);

    // 描く引数。**生存数は最上段の 1 個**で、スキャンが全部の区画を足し上げてある
    if (id == 0) {
        uint top = as_type<uint>(parameters[22 + levelCount]);
        arguments->vertexCount = as_type<uint>(parameters[21]);
        arguments->instanceCount = levels[top];
        arguments->vertexStart = as_type<uint>(parameters[20]);
        arguments->baseInstance = 0;
    }

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
            const device float *f = parameters + 32 + i * 8;
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

    // **死んだ粒は置かない。** 描く個数を GPU 側で決めるので、出ない粒は頂点段を通らない
    if (!survives) return;

    // 自分より前 (枠の番号が小さい) に生き残る粒の数。段 k は 256^k 個ごとの区画の中で
    // の順位を持つので、各段の自分の区画の値を足す
    uint place = 0;
    for (uint k = 0; k < levelCount; k++) {
        uint base = as_type<uint>(parameters[22 + k]);
        place += levels[base + (id >> (8 * k))];
    }

    // いまの変換。**置き場所の先頭 16 個**に置かれている
    float4x4 world = float4x4(
        float4(parameters[0], parameters[1], parameters[2], parameters[3]),
        float4(parameters[4], parameters[5], parameters[6], parameters[7]),
        float4(parameters[8], parameters[9], parameters[10], parameters[11]),
        float4(parameters[12], parameters[13], parameters[14], parameters[15]));
    float4x4 local = float4x4(
        float4(p.size, 0.0, 0.0, 0.0),
        float4(0.0, p.size, 0.0, 0.0),
        float4(0.0, 0.0, p.size, 0.0),
        float4(p.x, p.y, p.z, 1.0));

    SolidInstance placed;
    placed.matrix = world * local;
    placed.normal0 = float4(1.0, 0.0, 0.0, 0.0);
    placed.normal1 = float4(0.0, 1.0, 0.0, 0.0);
    placed.normal2 = float4(0.0, 0.0, 1.0, 0.0);
    placed.color = float4(p.red, p.green, p.blue, p.alpha);
    instances[place] = placed;
}

/// 自分が見ている配置を書き出す。**検査だけが呼ぶ。**
///
/// 大きさを両側に手で書いて突き合わせる形では、**両方が同時にずれたときに黙って通る**。
/// ここは項目に 1…14 を名前で入れて 2 つ並べて書くので、順序が入れ替わっても・項目が
/// 増減しても・間隔が違っても、CPU 側が読んだ数の並びが合わなくなる。
kernel void mokume_particleLayout(
    device Particle *particles [[buffer(0)]],
    device SolidInstance *instances [[buffer(1)]],
    device DrawArguments *arguments [[buffer(2)]],
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

    // 描く引数は 1…4 を名前で。2 つめの先頭にはスキャンの区画の大きさを置く —
    // 両側に手で書いた定数が、ここで初めて突き合わさる
    DrawArguments a;
    a.vertexCount = 1u;
    a.instanceCount = 2u;
    a.vertexStart = 3u;
    a.baseInstance = 4u;
    arguments[0] = a;
    a.vertexCount = MOKUME_PARTICLE_BLOCK;
    arguments[1] = a;
}
