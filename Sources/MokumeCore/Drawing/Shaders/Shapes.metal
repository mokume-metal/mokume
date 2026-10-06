// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 組み込みの描画。共通部分 (Common.metal) が前に付いた状態で組み立てられる。

struct ShapeVertex {
    float2 position;
    float2 uv;
    float4 color;
};

/// 平面の図形を置く 1 か所ぶん。並びは Swift 側の `FlatInstance` と一致する。
struct FlatInstance {
    float4 linear;
    float4 offset;
    float4 fill;
    float4 stroke;
};

/// 列ごとに変わらないもの。並びは Swift 側の `FlatFrame` と一致する。
/// **平面は行列と番号を、立体は行列と寄せを、基本図形は行列と描く画素の大きさを読む。**
struct FlatFrame {
    float4x4 projection;
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    /// 畳めない列は塗りしか無い扱い (置き場所の 2 色がどちらも白なので同じ)。
    uint strokeStart;
    /// 立体の輪郭の頂点を画面で (+0.5, +0.5) 画素寄せる量 (切り取り座標。`w` を掛けて足す)。
    float4 strokeShift;
    /// 描く画素 1 つが描画先の座標でいくらか (x, y)。細かさ 1 ならちょうど 1
    /// (`formVertexMain`・[#1488])。
    ///
    /// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
    float2 unitsPerDrawnPixel;
    /// 平面の頂点ごとの被覆 (`coverages`) を読むか。0 なら読まずに 1 とする (#1637)。
    uint readsCoverage;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant FlatInstance *instances [[buffer(10)]],
    constant float *coverages [[buffer(12)]])
{
    ShapeVertex vertex_in = vertices[index];
    FlatInstance placement = instances[instance];

    // **形自身の座標を、置き場所の変換で描画先の座標へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、畳めない頂点も同じ経路を通る
    float2 placed = placement.linear.xy * vertex_in.position.x
        + placement.linear.zw * vertex_in.position.y + placement.offset.xy;
    // **畳んだ雛形の輪郭は、置いた後・投影の前に半画素寄せる。** 塗りは整数の座標で
    // 画素の境目、線は画素の中心に乗る約束で (ADR-0039 決定 2)、置き場所ごとに回転や
    // 拡大が違っても画面でちょうど半画素になるよう、変換の後で足す。畳めない列は番号が
    // 最大なので足さない — そちらは CPU が描画先の座標で足し終えている (`Canvas+Outline`)
    if (index >= frame.strokeStart) {
        placed += 0.5;
    }

    ShapeFragmentIn out;
    out.position = frame.projection * float4(placed, 0.0, 1.0);
    out.uv = vertex_in.uv;
    // 置き場所の色は**頂点の色に掛かる**。畳んだ雛形は頂点が白、畳めない頂点は置き場所が
    // 白なので、どちらもこの 1 本で通る (立体と同じ)
    out.color = vertex_in.color
        * (index < frame.strokeStart ? placement.fill : placement.stroke);
    // 平面は光を受けない。列が「光 0 個」を渡すので、ここは 0 で足りる
    out.worldPosition = float3(0.0);
    out.normal = float3(0.0);
    out.isDerivedNormal = 0.0;
    // **利用者の断片へは 0 が届く。** 畳んだ雛形は形自身の座標を持つが、畳めない頂点
    // (字・画像・その場で並べたもの) は変換が焼き込まれていて持たない — 経路によって
    // 意味の変わる値を渡すくらいなら、平面は一貫して持たない側に置く
    out.shapePosition = float3(0.0);
    out.shapeNormal = float3(0.0);
    // 細い線を広げた頂点だけが 1 未満の被覆を持つ (#1637)。持つ頂点の無いフレームは読まない
    out.coverage = frame.readsCoverage != 0 ? coverages[index] : 1.0;
    return out;
}

/// 組み込みの塗り。
///
/// **読む面はどれも色である** — 字形を焼いた面も画像も、線形・アルファ乗算済みの
/// 色を持つ。だから式は 1 本で足りる: 読んだ色に頂点の色を掛ける。
///
/// - 図形は白い区画を指すので、掛けても色は変わらない
/// - 単色の字は白で焼かれている (`RGB == A`) ので、「塗りの色 × 覆い」になる
/// - 色を持つ字形 (絵文字) には、積む側が「白 × 塗りの透明度」を載せてくるので、
///   字形の色がそのまま出て塗りの透明度だけが効く (``Canvas``)
/// - 画像は色掛けが掛かる
float4 paint(Fragment in, Values values) {
    return in.texel * in.color;
}

// MARK: - 立体
//
// 立体の頂点も**平面と同じ塗りを通る**。ここが出すのは平面と同じ `ShapeFragmentIn` で、
// 混ぜ方も利用者が書いた断片も、平面のときとまったく同じ経路で効く。だから塗りを
// 2 本に分けない — 分ければ、片方にだけ効く性質がいずれ生まれる。

struct SolidVertex {
    /// **形自身の座標。** 世界へ移すのは置き場所の仕事である。
    float3 position;
    /// 利用者の断片へ渡す、形自身の座標 (Swift 側の `SolidVertex` を参照)。
    /// 置き場所が変換を持つ形では `position` と同じ値で、変換を頂点へ焼き込む形
    /// (頂点を並べて作った形) だけが違う値を持つ。
    float3 shapePosition;
    /// xyz が面の向き、w が 1 なら**形から求めた向き** (Swift 側の `SolidVertex` を参照)。
    float4 normal;
    /// 利用者の断片へ渡す、形自身の座標での面の向き。
    float3 shapeNormal;
    float2 uv;
    /// 0 でなければ**輪郭の頂点**で、値はその被覆 (Swift 側の `SolidVertex` を参照)。頂点関数が
    /// 画面で半画素寄せる
    float stroke;
    float4 color;
};

/// 同じ形を置く 1 か所ぶん。並びは Swift 側の `SolidInstance` と一致する。
struct SolidInstance {
    float4x4 matrix;
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 color;
};

/// 立体の頂点を落とす。
///
/// **影の焼き付けもこの関数で行う** — 渡す行列だけが光から見たものになり、断片は
/// 付けない (奥行きの面へは前後判定が書く)。焼き付けた形と画面に出る形が違って
/// しまわないよう、経路を分けない。
vertex ShapeFragmentIn solidVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant SolidVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant SolidInstance *instances [[buffer(10)]])
{
    SolidVertex vertex_in = vertices[index];
    SolidInstance placement = instances[instance];

    // **形自身の座標を、置き場所の変換で世界へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、その場で並べた頂点も
    // 同じ経路を通せる
    float4 world = placement.matrix * float4(vertex_in.position, 1.0);
    float3x3 normalMatrix = float3x3(
        placement.normal0.xyz, placement.normal1.xyz, placement.normal2.xyz);

    ShapeFragmentIn out;
    out.position = frame.projection * world;
    // **輪郭だけを画面で半画素寄せる** (ADR-0039 決定 2)。立体の頂点は投影の後でしか
    // 画面の位置が決まらないので、切り取り座標で `w` を掛けて足す。影の焼き付けは
    // 寄せ 0 を渡す
    // 寄せは輪郭なら被覆によらず 1 画素の半分 (`stroke` は被覆を兼ねる・#1637)
    bool isStroke = vertex_in.stroke > 0.0;
    out.position.xy += (isStroke ? 1.0 : 0.0) * frame.strokeShift.xy * out.position.w;
    out.uv = vertex_in.uv;
    // 置き場所の色は**頂点の色に掛かる**。組み込みの形は頂点が白、頂点ごとに色を
    // 変えた形は置き場所が白なので、どちらもこの 1 本で通る
    out.color = vertex_in.color * placement.color;
    // 光は世界の座標で当たるので、移したあとの位置と向きを渡す
    out.worldPosition = world.xyz;
    out.normal = normalMatrix * vertex_in.normal.xyz;
    out.isDerivedNormal = vertex_in.normal.w;
    // **利用者の断片へは、移す前の値をそのまま渡す。** 置き場所を通していないので
    // 形を動かしても回しても変わらず、ここから作った模様は形の表面に留まる (#367)
    out.shapePosition = vertex_in.shapePosition;
    out.shapeNormal = vertex_in.shapeNormal;
    out.coverage = isStroke ? vertex_in.stroke : 1.0;
    return out;
}

// 骨は形ごとに共用し、帯と角を置き場所・視点から頂点段で広げる (#1738)。
// 片の意味は `SolidStrokeGeometry.Piece` が持つ (a.w: 0 帯・2 網の点の半分・3 端の円板の 8 分の 1)。
struct SolidStrokePiece {
    float4 a;
    float4 b;
    float4 c;
};
struct SolidStrokePlacement {
    float4x4 matrix;
    float4 eye;
    float4 right;
    float4 down;
    float4 forward;
    float4 parameters;
    float4 color;
    float4 uv;
};

float solidStrokePixel(float3 p, constant SolidStrokePlacement &s) {
    if (s.eye.w != 0) {
        float depth = max(dot(p - s.eye.xyz, s.forward.xyz), s.parameters.z);
        return s.parameters.y * depth / s.parameters.w;
    }
    return s.parameters.y / s.parameters.w;
}

/// 線分 a–b を画面に写したときの垂線の、画面の横と縦の成分 (長さ 1) を `normal` に入れる。
/// CPU の `Canvas.screenNormal` と同じ式。画面での長さが 0 の線 (と長さ 0 の線分) なら偽。
bool solidStrokeNormal(float3 a, float3 b, constant SolidStrokePlacement &s, thread float2 &normal) {
    float3 along = b - a;
    float2 raw;
    if (s.eye.w != 0) {
        float3 plane = cross(a - s.eye.xyz, b - s.eye.xyz);
        raw = float2(dot(plane, s.right.xyz), dot(plane, s.down.xyz));
    } else {
        raw = float2(-dot(along, s.down.xyz), dot(along, s.right.xyz));
    }
    float size = length(raw);
    if (!(dot(along, along) > 0 && size > 0 && isfinite(size))) return false;
    normal = raw / size;
    return true;
}

/// 線分 a–b を画面に写したときの垂線を、世界の向き (長さ 1) で `side` に入れる。CPU の
/// `Canvas.screenAcross` と同じ式。画面での長さが 0 の線 (と長さ 0 の線分) なら偽。
bool solidStrokeAcross(float3 a, float3 b, constant SolidStrokePlacement &s, thread float3 &side) {
    float2 normal;
    if (!solidStrokeNormal(a, b, s, normal)) return false;
    side = s.right.xyz * normal.x + s.down.xyz * normal.y;
    return true;
}

/// 線分 a → b を画面に写したときの、a から b へ進む向き (画面の横と縦の成分・長さ 1) を
/// `toward` に入れる。CPU の `Canvas.screenToward` と同じ式で、垂線を 90° 回す向きは透視と
/// 平行で逆になる (画面の横 × 縦 = −前)。
bool solidStrokeToward(float3 a, float3 b, constant SolidStrokePlacement &s, thread float2 &toward) {
    float2 normal;
    if (!solidStrokeNormal(a, b, s, normal)) return false;
    toward = s.eye.w != 0 ? float2(-normal.y, normal.x) : float2(normal.y, -normal.x);
    return true;
}

/// 画面の軸に沿った正方形の、6 頂点の並びの隅 (0…3) の向き。
float3 solidStrokeSquareCorner(uint corner, constant SolidStrokePlacement &s) {
    switch (corner) {
        case 0: return -s.right.xyz - s.down.xyz;
        case 1: return s.right.xyz - s.down.xyz;
        case 2: return s.right.xyz + s.down.xyz;
        default: return -s.right.xyz + s.down.xyz;
    }
}

/// 円板の周の点の向き (画面の横と縦の成分)。CPU の円板の下限の分割数 (16) の周の点
/// (`Canvas.solidDiscFloorUnits`。`cos` / `sin` で求める) をそのまま書き写したもの (0 番は横そのもの)。
/// 検査 (`SolidGPUStrokeTests.discUnitsMatchTheCPU`) が CPU の値とビットで突き合わせる。CPU は円板を
/// 画面の半径で刻む (#2011) が、16 で足りない太さの丸い端は骨を使わずに CPU で組む
/// (`Canvas.gpuStrokeGeometry`) ので、ここに要るのは 16 等分の表だけである。下限
/// (`Canvas.solidDiscFloorSegments`) を変えるときは、`SolidStrokeGeometry` の円板の片の数 (8 = 下限の
/// 半分) と、この表を読む検査 (`SolidGPUStrokeTests.discUnitsMatchTheCPU`) も揃える。
constant float2 kSolidStrokeDisc[17] = {
    float2(1, 0),
    float2(0.92387956, 0.38268343),
    float2(0.7071068, 0.70710677),
    float2(0.38268343, 0.9238795),
    float2(7.54979e-08, 1.0),
    float2(-0.38268328, 0.92387956),
    float2(-0.70710677, 0.70710677),
    float2(-0.9238795, 0.3826835),
    float2(-1.0, 1.509958e-07),
    float2(-0.9238796, -0.38268322),
    float2(-0.707107, -0.7071066),
    float2(-0.38268358, -0.9238795),
    float2(1.1924881e-08, -1.0),
    float2(0.38268316, -0.9238796),
    float2(0.70710665, -0.7071069),
    float2(0.9238794, -0.38268387),
    float2(1.0, -3.019916e-07),
};

/// 骨の点の位置 (形自身の座標) を、置いた後の世界の座標へ移す。
float3 solidStrokePlaced(float3 shape, constant SolidStrokePlacement &s) {
    return (s.matrix * float4(shape * s.uv.z, 1)).xyz;
}

/// 頂点関数が向きを控える腕の数。辺が 4 本の格子の点と、画面で重なる 2 点 (辺 3 本 + 3 本) まで
/// 収まる。越えた腕 (球の極・円錐の頂点) は、引くたびに求め直す
constant uint kSolidStrokeCachedArms = 8;

/// 画面で重なる点の群 (形を置く手前の点 i と、画面で潰れた辺の先の点 j)。腕は i の隣 (j を除く) を
/// 辺の順に、続けて j の隣 (i を除く) を辺の順に並べる (CPU の `strokeNet` の、代表を先にした群の
/// 点の順と同じ)。
struct SolidStrokeGroup {
    /// i と j が世界で同じ位置か。同じ位置なら同じ点として数え、腕を 1 本にまとめない
    /// (CPU の `strokeNet` の `samePoint`)
    bool sameOrigin;
    uint recordI;
    uint recordJ;
    uint partnerAt;   // i の隣の並びでの j の位置
    uint selfAt;      // j の隣の並びでの i の位置
    uint armsI;       // i から出る腕の数
    uint arms;
    float2 toward[8];
    bool valid[8];
};

/// 群の腕 t の、出る点と向こうの点。
void solidStrokeArmPoints(
    thread const SolidStrokeGroup &g, uint t, constant float4 *words, constant SolidStrokePlacement &s,
    thread float3 &origin, thread float3 &far)
{
    if (t < g.armsI) {
        uint k = t >= g.partnerAt ? t + 1 : t;
        origin = solidStrokePlaced(words[g.recordI].xyz, s);
        far = solidStrokePlaced(words[g.recordI + 1 + k].xyz, s);
    } else {
        uint u = t - g.armsI;
        uint k = u >= g.selfAt ? u + 1 : u;
        origin = solidStrokePlaced(words[g.recordJ].xyz, s);
        far = solidStrokePlaced(words[g.recordJ + 1 + k].xyz, s);
    }
}

/// 群の腕 t の画面での向き。腕が画面で潰れていれば偽 (数えない)。
bool solidStrokeArmToward(
    thread const SolidStrokeGroup &g, uint t, constant float4 *words, constant SolidStrokePlacement &s,
    thread float2 &toward)
{
    if (t < kSolidStrokeCachedArms) {
        toward = g.toward[t];
        return g.valid[t];
    }
    float3 origin;
    float3 far;
    solidStrokeArmPoints(g, t, words, s, origin, far);
    return solidStrokeToward(origin, far, s, toward);
}

/// 腕 t を数えるか。**別の点から出た同じ向きの腕は 1 本と数える** — j から出た腕は、i から出た
/// 腕と値が等しければ数えない (CPU の `Canvas.screenCorner` と同じ)。
bool solidStrokeArmKept(
    thread const SolidStrokeGroup &g, uint t, constant float4 *words, constant SolidStrokePlacement &s,
    thread float2 &toward)
{
    if (!solidStrokeArmToward(g, t, words, s, toward)) return false;
    if (t < g.armsI || g.sameOrigin) return true;
    for (uint m = 0; m < g.armsI; m++) {
        float2 other;
        if (solidStrokeArmToward(g, m, words, s, other) && all(other == toward)) return false;
    }
    return true;
}

float solidStrokeCross(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

/// 骨の 2 点を結ぶ辺が画面で潰れているか。**辺の両端が同じ答えを得るよう、記録の位置が小さい点を
/// 先にして同じ式で判定する** — 引数の順を入れ替えると、fast-math の積和の縮約で外積が 0 に
/// なるかどうかが端ごとに食い違いうる
bool solidStrokeEdgeCollapsed(
    float3 p, uint recordP, float3 q, uint recordQ, constant SolidStrokePlacement &s)
{
    float2 normal;
    return recordP < recordQ ? !solidStrokeNormal(p, q, s, normal) : !solidStrokeNormal(q, p, s, normal);
}

/// 骨の点の奥行き (視点からの、視線に沿った距離)。CPU の `strokeNet` に渡す奥行きと同じ式
float solidStrokeDepth(float3 p, constant SolidStrokePlacement &s) {
    return dot(p - s.eye.xyz, s.forward.xyz);
}

/// 網の点に置く形 (CPU の `Canvas.screenCorner` と同じ手順)。
struct SolidStrokeCorner {
    /// 0 何も置かない・1 円板・2 画面の軸の正方形・3 出っ張らせる端・4 折れ目
    uint kind;
    float3 center;
    float3 origin1;
    float3 far1;
    float3 origin2;
    float3 far2;
};

/// 点の記録 `record` の点に置く形を決める (#1889・#1893・#1903 の決定)。
///
/// 画面で潰れた辺で結ばれた点 (1 段まで) を群とし、群のいちばん手前の点 (奥行きが等しければ記録の
/// 位置が小さい点) だけが置く (CPU の `strokeNet` と同じ選び方)。
/// 群に集まる腕の画面での向きの数で、0 なら向きの無い点 (正方形)・1 なら端 (`strokeCap`)・
/// 2 なら 2 本の折れ目・3 以上なら角度の順で 180° を越える間を挟む 2 本の折れ目 (無ければ何も
/// 置かない)。`roundEnd` は端の円板を置く容量を持つか。持たない点では、端の円板の代わりに
/// 2 本の腕の折り返しの形を置く。容量は画面で 1 本になりうる点 (同じ平面に載る 4 点・
/// `Canvas.mayMeetAsOneBand`) にあり、画面で値が等しいほど揃った腕はその中に入る。
SolidStrokeCorner solidStrokeCornerShape(
    uint record, bool roundEnd, constant float4 *words, constant SolidStrokePlacement &s)
{
    SolidStrokeCorner result;
    result.kind = 0;
    SolidStrokeGroup g;
    g.recordI = record;
    float4 header = words[record];
    uint countI = uint(header.w);
    float3 center = solidStrokePlaced(header.xyz, s);
    result.center = center;
    g.partnerAt = countI;
    g.recordJ = record;
    g.selfAt = 0;
    uint partners = 0;
    for (uint k = 0; k < countI; k++) {
        float4 entry = words[record + 1 + k];
        if (solidStrokeEdgeCollapsed(center, record, solidStrokePlaced(entry.xyz, s), uint(entry.w), s)) {
            if (partners == 0) {
                g.partnerAt = k;
                g.recordJ = uint(entry.w);
            }
            partners++;
        }
    }
    // 潰れた辺が 2 本続く群は骨を作らない (`SolidStrokeGeometry`)。手前の点でなければ置かない
    if (partners > 1) return result;
    g.sameOrigin = false;
    if (partners == 1) {
        float3 partner = solidStrokePlaced(words[g.recordJ].xyz, s);
        float depthI = solidStrokeDepth(center, s);
        float depthJ = solidStrokeDepth(partner, s);
        if (depthJ < depthI || (depthJ == depthI && g.recordJ < record)) return result;
        g.sameOrigin = all(partner == center);
    }
    g.armsI = partners == 1 ? countI - 1 : countI;
    g.arms = g.armsI;
    if (partners == 1) {
        uint countJ = uint(words[g.recordJ].w);
        g.selfAt = countJ;
        for (uint k = 0; k < countJ; k++) {
            if (uint(words[g.recordJ + 1 + k].w) == record) {
                g.selfAt = k;
                break;
            }
        }
        g.arms += countJ - 1;
    }
    for (uint t = 0; t < kSolidStrokeCachedArms; t++) {
        g.valid[t] = false;
        g.toward[t] = float2(0);
        if (t < g.arms) {
            float3 origin;
            float3 far;
            solidStrokeArmPoints(g, t, words, s, origin, far);
            g.valid[t] = solidStrokeToward(origin, far, s, g.toward[t]);
        }
    }
    uint kept = 0;
    uint firstKept = 0;
    uint secondKept = 0;
    for (uint t = 0; t < g.arms; t++) {
        float2 toward;
        if (!solidStrokeArmKept(g, t, words, s, toward)) continue;
        if (kept == 0) firstKept = t;
        else if (kept == 1) secondKept = t;
        kept++;
    }
    uint a = firstKept;
    uint b = secondKept;
    uint cap = uint(s.right.w);  // 0 丸・1 切る・2 出っ張らせる (`SolidStrokePlacement.capCode`)
    if (kept == 0) {
        result.kind = 2;
        return result;
    } else if (kept == 1) {
        if (cap == 1) return result;
        if (cap == 2) {
            result.kind = 3;
        } else if (roundEnd) {
            result.kind = 1;
            return result;
        } else {
            // 容量の無い点では 1 本と数えない (2 本の腕の折り返し)
            if (g.arms < 2) return result;
            result.kind = 4;
            a = 0;
            b = 1;
        }
    } else if (kept == 2) {
        result.kind = 4;
    } else {
        // 角度を求めずに外積の符号で、時計回りの端と反時計回りの端を前から探す。等しい向きは
        // 外積を見ない (fast-math は積和を縮約するので、等しい 2 本の外積が 0 にならない)
        float2 first;
        solidStrokeArmToward(g, a, words, s, first);
        for (uint t = a + 1; t < g.arms; t++) {
            float2 toward;
            if (!solidStrokeArmKept(g, t, words, s, toward)) continue;
            if (any(toward != first) && solidStrokeCross(first, toward) < 0) {
                a = t;
                first = toward;
            }
        }
        for (uint t = 0; t < g.arms; t++) {
            float2 toward;
            if (t == a || !solidStrokeArmKept(g, t, words, s, toward)) continue;
            float turn = solidStrokeCross(first, toward);
            if (!(all(toward == first) || turn > 0 || (turn == 0 && dot(first, toward) > 0))) return result;
        }
        b = a;
        float2 last = first;
        for (uint t = 0; t < g.arms; t++) {
            float2 toward;
            if (!solidStrokeArmKept(g, t, words, s, toward)) continue;
            if (any(toward != last) && solidStrokeCross(last, toward) > 0) {
                b = t;
                last = toward;
            }
        }
        result.kind = 4;
    }
    solidStrokeArmPoints(g, a, words, s, result.origin1, result.far1);
    solidStrokeArmPoints(g, b, words, s, result.origin2, result.far2);
    return result;
}

vertex ShapeFragmentIn solidStrokeVertexMain(
    uint index [[vertex_id]],
    constant SolidStrokePiece *pieces [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant SolidStrokePlacement &s [[buffer(5)]])
{
    SolidStrokePiece piece = pieces[index / 6];
    // 点の記録は片の後ろに積んである (`SolidStrokeGeometry.Piece`)
    constant float4 *words = (constant float4 *)pieces;
    const uint corners[6] = {0, 1, 2, 0, 2, 3};
    uint corner = corners[index % 6];
    float3 shapeA = piece.a.xyz * s.uv.z;
    float3 shapeB = piece.b.xyz * s.uv.z;
    float3 a = (s.matrix * float4(shapeA, 1)).xyz;
    float3 world = a;
    float3 shape = shapeA;
    float halfWeight = s.parameters.x / 2;
    if (piece.a.w == 0) {
        float3 b = (s.matrix * float4(shapeB, 1)).xyz;
        float3 side;
        // CPU が積まない帯は面積0にする。角は独立した部品のまま残る。
        if (solidStrokeAcross(a, b, s, side)) {
            bool end = corner == 1 || corner == 2;
            float3 center = end ? b : a;
            float3 across = side * (halfWeight * solidStrokePixel(center, s));
            world = corner < 2 ? center + across : center - across;
            shape = end ? shapeB : shapeA;
        }
    } else if (piece.a.w == 3) {
        // 端の円板の 8 分の 1 (三角形 2 枚)。CPU の `appendSolidDisc` の扇の 2 枚ずつ。8 と表の 17 点は
        // 下限の分割数 16 から来る (揃える相手は `kSolidStrokeDisc` の説明)
        SolidStrokeCorner placed = solidStrokeCornerShape(uint(piece.b.x), true, words, s);
        if (placed.kind == 1) {
            float radius = halfWeight * solidStrokePixel(placed.center, s);
            uint step = uint(piece.b.y) * 2 + (corner == 0 ? 0 : corner - 1);
            float2 unit = kSolidStrokeDisc[step];
            world = corner == 0 ? placed.center
                : placed.center + (s.right.xyz * unit.x + s.down.xyz * unit.y) * radius;
        }
    } else {
        // 網の点の半分 (#1644・#1889・#1893)。形は点の記録から決める (`solidStrokeCornerShape`)
        bool firstHalf = piece.b.y == 0;
        SolidStrokeCorner placed = solidStrokeCornerShape(uint(piece.b.x), piece.b.z != 0, words, s);
        float3 center = placed.center;
        float radius = halfWeight * solidStrokePixel(center, s);
        world = center;
        if (placed.kind == 2 && firstHalf) {
            // 向きの無い点 (画面の 1 点に潰れた形の全体)。画面の軸に沿った正方形
            world = center + solidStrokeSquareCorner(corner, s) * radius;
        } else if (placed.kind == 3 && firstHalf) {
            // 出っ張らせる端。CPU の `appendSolidSquare(at:awayFrom:shape:half:camera:)` と同じ 2 軸
            float3 right;
            if (solidStrokeAcross(placed.far1, center, s, right)) {
                float3 down = s.right.xyz * -dot(right, s.down.xyz) + s.down.xyz * dot(right, s.right.xyz);
                switch (corner) {
                    case 0: world = center + (-right - down) * radius; break;
                    case 1: world = center + (right - down) * radius; break;
                    case 2: world = center + (right + down) * radius; break;
                    default: world = center + (-right + down) * radius; break;
                }
            }
        } else if (placed.kind == 4) {
            // 2 本の腕の折れ目の、二等分線で割った半分 (#1644)。形は CPU の `Canvas.joinRim` の
            // `miter` (尖りを角から √2 × 太さの半分で切る) と同じ式で、画面に写した 2 本の帯の
            // 向きから決める。GPU で組む線は `miter` だけである (`gpuStrokeStyleAllows`)。4 隅は
            // 角のすぐ内側・自分の側の外側の縁の角・切り口 (か尖り)・二等分線の上の切り口の中点
            // (か尖り) で、2 枚を合わせると CPU の周になる。腕の出る点は角と画面で重なる点で、
            // 形は角の位置に置く (CPU の `buildSolidJoin`)
            float3 ownOrigin = firstHalf ? placed.origin1 : placed.origin2;
            float3 own = firstHalf ? placed.far1 : placed.far2;
            float3 otherOrigin = firstHalf ? placed.origin2 : placed.origin1;
            float3 other = firstHalf ? placed.far2 : placed.far1;
            float3 acrossOwn;
            float3 acrossOther;
            float2 armOwn;
            float2 armOther;
            bool built = solidStrokeAcross(own, ownOrigin, s, acrossOwn)
                && solidStrokeAcross(otherOrigin, other, s, acrossOther)
                && solidStrokeToward(ownOrigin, own, s, armOwn) && solidStrokeToward(otherOrigin, other, s, armOther);
            float2 inward = armOwn + armOther;
            if (built && !(inward.x == 0 && inward.y == 0)) {
                float2 sideOwn = float2(dot(acrossOwn, s.right.xyz), dot(acrossOwn, s.down.xyz));
                // 同じ向きへ折り返す角では、2 枚が外側の縁を左右へ分ける (`b.y`)
                float2 outerOwn = firstHalf ? float2(-armOwn.y, armOwn.x) : float2(armOwn.y, -armOwn.x);
                if (dot(outerOwn, inward) > 0) outerOwn = -outerOwn;
                float2 outerOther = firstHalf ? float2(armOther.y, -armOther.x) : float2(-armOther.y, armOther.x);
                if (dot(outerOther, inward) > 0) outerOther = -outerOther;
                // 丸めで −1…1 を越えると、同じ向きへ折り返す角で平方根が数でなくなる
                float cosine = clamp(dot(outerOwn, outerOther), -1.0f, 1.0f);
                float2 cut;
                float2 middle;
                if (cosine >= 0) {
                    cut = (outerOwn + outerOther) * (1 / (1 + cosine));
                    middle = cut;
                } else {
                    float halfCosine = sqrt((1 + cosine) / 2);
                    float halfSine = sqrt((1 - cosine) / 2);
                    float extent = (M_SQRT2_F - halfCosine) / halfSine;
                    cut = outerOwn - armOwn * extent;
                    middle = -normalize(inward) * M_SQRT2_F;
                }
                float3 edge = (dot(outerOwn, sideOwn) > 0 ? acrossOwn : -acrossOwn) * radius;
                // 角のすぐ内側 (CPU の `joinRim` の周の最初の点)。角を片の内に入れる
                float2 inner = normalize(inward) / 64;
                switch (corner) {
                    case 0: world = center + (s.right.xyz * inner.x + s.down.xyz * inner.y) * radius; break;
                    case 1: world = center + edge; break;
                    case 2: world = center + (s.right.xyz * cut.x + s.down.xyz * cut.y) * radius; break;
                    default: world = center + (s.right.xyz * middle.x + s.down.xyz * middle.y) * radius; break;
                }
            }
        }
    }
    float lift = (s.parameters.x + 1) * solidStrokePixel(world, s);
    if (s.eye.w != 0) {
        float3 toEye = s.eye.xyz - world;
        float distance = length(toEye);
        if (distance > 0) world += toEye / distance * min(lift, distance / 2);
    } else {
        world -= s.forward.xyz * lift;
    }
    ShapeFragmentIn out;
    out.position = frame.projection * float4(world, 1);
    out.position.xy += frame.strokeShift.xy * out.position.w;
    out.uv = s.uv.xy;
    out.color = s.color;
    out.worldPosition = world;
    out.normal = float3(0);
    out.isDerivedNormal = 0;
    out.shapePosition = shape;
    out.shapeNormal = float3(0);
    // 被覆は置き場所が持つ (細い線を広げたとき 1 未満・#1637)
    out.coverage = s.uv.w;
    return out;
}

// MARK: - 平面の基本図形 (1 インスタンス = 1 クアッド + 距離関数)
//
// 矩形・楕円・扇形・線・点は、頂点を組み立てずに描く。置き場所 1 つが形の寸法まで持ち、
// 頂点関数はクアッドの 4 角を置くだけ、断片関数が距離関数で「この画素は形の内か・輪郭の
// 上か」を決める。寸法が置き場所に載っているので、寸法違いの図形も 1 つの列に並ぶ (#752)。
//
// **縁は 1 画素幅で滑らかにする** (被覆率を距離から出す)。三角形で描いていた頃の
// ギザギザの縁は出ない。**位置・大きさ・色は三角形のときと同じ**で、動くのは縁の 1 画素
// だけである。

/// 基本図形を 1 つ置く。並びは Swift 側の `FormInstance` と一致する。
struct FormInstance {
    /// 形自身の座標を描画先の座標へ移す 2x2 (列 2 本)。線は線の向きの回転を含む
    float4 linear;
    /// xy: 平行移動 (形の中心)。zw: 扇形の開始角と掃引
    float4 offset;
    /// xy: 半幅・半高 (楕円は半径。線は半分の長さと 0)。z: 線幅の半分 (輪郭が無ければ 0)
    float4 size;
    /// 塗り (乗算済み線形)。塗りが無ければ 0
    float4 fill;
    /// 輪郭 (乗算済み線形)。輪郭が無ければ 0
    float4 stroke;
    /// x: 種別, y: 端の形, z: 折れ目の形, w: 旗 (塗りあり = 1, 輪郭あり = 2)
    uint4 meta;
};

/// この列の図形が塗りを持つか・輪郭を持つか。**列ごとに決まる** ([#771])。
///
/// 旗を置き場所から読んで枝で分けていた頃は、輪郭を 1 本も描かない絵でも輪郭の距離場と
/// 被覆の式が組み上がった原稿に残っていた。**この GPU では、走らない綴りも居るだけで
/// 費用になる** — 面を覆う矩形 200 枚で 2.6 ms が、実行時には 1 度も通らない輪郭の綴りに
/// 押さえられていた (枝を実行時に飛ばす形では 1 ミリ秒も縮まなかった)。組で特化すると、
/// その列に無い側の綴りは原稿から消える。
///
/// 代償は列が塗り / 輪郭の有無で切れること (`Canvas.beginForm`)。寸法違い・種別違い・
/// 色違い・変換違いは今までどおり 1 列に並ぶ。
///
/// [#771]: https://github.com/mokume-metal/mokume/issues/771
constant bool kFormHasFill [[function_constant(0)]];
constant bool kFormHasStroke [[function_constant(1)]];

/// この列が、描く画素で 1 画素より細い塗りを含みうるか。**列ごとに決まる** ([#1477])。
///
/// 1 画素より細い塗りの枝 (`mokume_formPaint` の `rect` と楕円の塗り) も、上の 2 つと同じ
/// 理由で特化して外す。枝は細い塗りに 1 度も入らない絵でも費用になり、面を覆う矩形 200 枚
/// (塗りだけ・1920×1080) で GPU 時間が 28% 増えていた。境目の比べ方を軽くしても消えず、
/// 原稿から外すと戻った。
///
/// 決めるのは CPU で、置いた時点の変換と大きさから保守側に倒して判定する
/// (`FormInstance.mayHaveThinFill`)。立っていても、細くない形は枝の中の判定で今までどおりの
/// 式を通るので、絵は変わらない。**立てるべき列で立て損なうと、細い塗りが縁 1 本の式に
/// 戻って絵が変わる** — だから判定は迷ったら「含む」側にする。列は旗で切らない
/// (細い塗りと太い塗りが混ざった列は、含む側の組で描く)。
///
/// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
constant bool kFormHasThinFill [[function_constant(2)]];

/// 縁を滑らかにする余白 (描く画素)。被覆が 0 になるのは縁から 0.5 画素なので、微分の
/// 揺れを見込んで 2 画素取る
constant float kFormMargin = 2.0;

/// 被覆率の両端の遊び (`mokume_formCoverage`)。
constant float kFormSnap = 1.0 / 256.0;

struct FormFragmentIn {
    float4 position [[position]];
    /// 形自身の座標での位置。距離関数はこの座標で評価する
    float2 local;
    /// **描く画素** → 形自身の座標の 2x2 の 2 行。xy が 1 行目、zw が 2 行目。
    /// 形自身の座標での勾配を画面の勾配へ写すのに使う (`mokume_formCoverage`)。
    /// 描画先の座標ではなく描く画素を基準にする理由は頂点関数の説明にある
    float4 inverseRows [[flat]];
    /// 輪郭と線を評価する位置のずらし (形自身の座標)。画面の (0.5, 0.5) を写したもの (下の説明)
    float2 strokeShift [[flat]];
    /// 塗りと輪郭を両方持つ楕円の輪郭を、塗りの距離場からずらして出してよいか。楕円の
    /// インスタンスごとに決まる (`mokume_canShiftRing`)。0: 輪郭の位置で解き直す・
    /// 1: 距離場そのものの勾配でずらす (`mokume_shiftedBySlope`)・2: 円なので法線でずらす
    /// (`mokume_shifted`)
    uint ringFromFill [[flat]];
    uint instance [[flat]];
};

/// 楕円の輪郭を塗りの距離場から 1 次の近似でずらして出すときに、許す被覆率の誤差の見積もり
/// (`mokume_canShiftRing`)。表示の 1 段 (1/255) の半分である。
///
/// **見積もりは 1 次の項までで、厳密な上限ではない。** CPU の float64 のモデルで置き方を
/// 約 15,000 組探すと、実測は見積もりの最大で 1.04〜1.06 倍だった (半径 153.8・太さの半分 1.12
/// の円を、回して一様に 0.21 倍・細かさ 0.25 で置くと、見積もり 0.00195 に対して実測 0.00206)。
/// 1/255 (0.0039) の半分を余裕に取ってあるので、見積もりが最大で 6% ほど甘くても 1/255 の
/// 内側に収まる (その最悪の例で 1/255 の 0.53 倍)。実機の半精度は 1 ulp (≈ 0.0005) の差が
/// 両側に出るので、実測はそのぶんだけさらに大きい
constant float kFormShiftTolerance = 1.0 / 512.0;

/// 楕円の輪郭を、塗りの距離場から 1 次の近似でずらして出してよいか
/// (`mokume_shifted`・`mokume_shiftedBySlope`・[#1820](https://github.com/mokume-metal/mokume/issues/1820))。
///
/// **近似が落とす被覆率の誤差を 1 次の項までで見積もり、見積もりが `kFormShiftTolerance` に
/// 収まるときだけ真を返す。** 見積もりは輪郭の**内縁の曲率半径** `R` で決まる — 形自身の座標で
/// `短半径² / 長半径 − 太さの半分` (楕円の長軸の端で最も小さい。半径が太さの半分以下なら
/// 内縁が無いので、常に解き直す)。ずらし `s` (画面で半画素・長さ 0.71 画素) が落とすのは、
/// 2 次の項 `|s|² / (2R)` と、ずらしで法線が回って画素 1 つの距離が変わる項 (`|s| / R` に
/// 比例) である。
///
///     誤差 ≈ |s| / (2R) · (|s| / σmin + (σmax / σmin − σmin / σmax) / 2)
///
/// σmin・σmax は「描く画素 → 形自身の座標」の行列の特異値で、描く画素 1 つが形自身の座標で
/// いくらかの下限・上限である。回す・一様に拡大するだけなら σmin = σmax で、右の項は 0 になり、
/// 画素の大きさで測れば `0.25 / R` (画素) になる。**縦横で違う拡大・剪断では向きによって
/// 画素の大きさが違う**ので、小さいほう (σmin) で割って保守側に倒し、法線が回る項を足す。
///
/// この式は、楕円の距離場そのものの勾配で足す前提である (`mokume_shiftedBySlope`)。長さ 1
/// の向きで足すと、円でない楕円の誤差は上の式より大きくなる。円は真の距離で、どちらで足しても
/// 同じ。
///
/// 半径 29 の円に太さ 7 の輪郭 (R = 25.5) は見積もり 0.0098 で 1/255 (0.0039) を越え、解き直す。
/// 画素の大きさで測るので、描く細かさを下げた面 (描く画素が粗い面) では近似を使える
/// 範囲が広がる。**大きさが 0・壊れた変換は、割り算を避けて比べるので常に解き直す側**に倒れる。
static inline bool mokume_canShiftRing(
    float2 radii, float halfWeight, float2 shift, float4 drawnRows)
{
    float longRadius = max(max(radii.x, radii.y), 1e-30);
    float shortRadius = min(radii.x, radii.y);
    float innerRadius = shortRadius * shortRadius / longRadius - halfWeight;
    // 2x2 の特異値: 大きいほうは √((F² + √(F⁴ − 4·det²)) / 2) (F は全成分の 2 乗和の平方根)、
    // 小さいほうは |det| を大きいほうで割る (引き算の桁落ちを避ける)
    float determinant = abs(drawnRows.x * drawnRows.w - drawnRows.y * drawnRows.z);
    float squares = dot(drawnRows, drawnRows);
    float largest = sqrt(
        0.5 * (squares + sqrt(max(squares * squares - 4.0 * determinant * determinant, 0.0))));
    float smallest = max(determinant / max(largest, 1e-30), 1e-30);
    float rotation = 0.5 * (largest / smallest - smallest / largest);
    float shiftLength = sqrt(dot(shift, shift));
    return innerRadius > 0.0
        && shiftLength * (shiftLength / smallest + rotation)
            <= 2.0 * kFormShiftTolerance * innerRadius;
}

vertex FormFragmentIn formVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant FlatFrame &frame [[buffer(1)]],
    constant FormInstance *instances [[buffer(10)]])
{
    FormInstance form = instances[instance];
    float halfWeight = form.size.z;

    // 形が収まる半幅・半高 (形自身の座標)。輪郭のぶんだけ膨らませる。線は端の形が
    // 半分の太さだけ出っ張りうるので、長さの側にも足す
    float2 extent = form.meta.x == kFormLine
        ? float2(form.size.x + halfWeight, halfWeight)
        : form.size.xy + halfWeight;

    // 描画先 → 形自身の座標の逆行列。列が (a, b) と (c, d) なら、逆は (d, −c / −b, a) / det
    float2 columnX = form.linear.xy;
    float2 columnY = form.linear.zw;
    float determinant = columnX.x * columnY.y - columnX.y * columnY.x;
    float4 inverseRows = float4(columnY.y, -columnY.x, -columnX.y, columnX.x) / determinant;

    // **被覆は描く画素で測る** ([#1488](https://github.com/mokume-metal/mokume/issues/1488))。
    // 座標と太さは描画先の座標 (出す画素) で書かれ、描く画素への縮みは投影と見る窓が持つ。
    // 逆行列のままだと、細かさ 0.5 の面では描く画素 1 つを 1 単位と数えるので、縁を
    // 滑らかにする幅が描く画素の半分に縮む — 太さ 1 の線は描く画素では太さ 0.5 なのに
    // 被覆の式からは太さ 1 に見え、描く画素の中心が縁から 1 単位離れる位置に置くと
    // 消えていた。
    //
    // 描く画素の差 (px, py) は描画先の座標で (px · ux, py · uy) なので、逆行列の列に
    // (ux, uy) を掛ければ「描く画素 → 形自身の座標」になる。**割らずに掛ける** — 細かさ 1
    // ではちょうど 1 を掛けるので、値は 1 ビットも変わらない (割り算は速い数学の下で逆数の
    // 近似に置き換わりうる)
    float4 drawnRows = inverseRows * frame.unitsPerDrawnPixel.xyxy;

    // 縁の余白は**描く画素**で測る。形自身の座標では、上の行のノルムぶんになる —
    // 画面で半径 2 画素の円は、形自身の座標ではその楕円の外接する箱に収まる
    extent += kFormMargin * float2(length(drawnRows.xy), length(drawnRows.zw));

    // クアッドは三角形 2 枚 (0 1 2 / 0 2 3)。角の番号から符号を決める
    uint corner = index == 3 ? 0 : (index == 4 ? 2 : (index == 5 ? 3 : index));
    float2 sign = float2(
        (corner == 1 || corner == 2) ? 1.0 : -1.0,
        corner >= 2 ? 1.0 : -1.0);
    float2 local = sign * extent;
    float2 placed = columnX * local.x + columnY * local.y + form.offset.xy;

    FormFragmentIn out;
    out.position = frame.projection * float4(placed, 0.0, 1.0);
    out.local = local;
    out.inverseRows = drawnRows;
    // **輪郭と線は、画面で半画素寄せて評価する。** 整数の座標は画素の角に落ちるので、
    // 塗りの縁は整数の座標で画素の境目に乗り、`rect(10, 20, 4, 8)` はちょうど 4x8 画素を
    // 塗る。輪郭は縁の上に中心を持つ帯なので、そのまま置くと太さ 1 の線が 2 列の画素を
    // 半分ずつ塗って滲む。だから線の側を寄せて、中心を画素の中心に乗せる (ADR-0039 決定 2)。
    // 三角形で描く輪郭も同じだけ寄せている (`Canvas+Outline`・`shapeVertexMain`)。
    //
    // ずらしは画面の (0.5, 0.5) を形自身の座標へ逆行列で写したもの — 拡大しても回しても
    // 画面上で半画素になる。**長さの向きにも寄せる**ので、端点と点も三角形のときと同じ
    // 画素に乗る。評価する位置を戻す向き (`p − ずらし`) で掛けるので、帯は画面で +0.5 動く
    //
    // **寄せは出す画素で測り、描く画素では測らない** — 被覆と違ってここは描画先の座標の
    // 逆行列のまま写す。三角形の経路も立体も出す画素で寄せる (`Canvas.solidStrokeShift`) ので、
    // ここだけ描く画素にすると、細かさ < 1 で経路によって同じ線がずれる
    out.strokeShift = 0.5 * float2(inverseRows.x + inverseRows.y, inverseRows.z + inverseRows.w);
    // 楕円の輪郭を塗りの距離場からずらしてよいか。インスタンスごとの量なので、頂点で 1 度
    // だけ出して断片へ渡す (断片で出すと、画素ごとに同じ式を解く)
    out.ringFromFill =
        (form.meta.x == kFormEllipse
            && mokume_canShiftRing(form.size.xy, halfWeight, out.strokeShift, drawnRows))
        ? (form.size.x == form.size.y ? 2u : 1u) : 0u;
    out.instance = instance;
    return out;
}

// MARK: 距離場
//
// 距離関数はどれも **(符号つき距離, 勾配の向き)** の組を返す。勾配は形自身の座標で長さ 1
// (真の距離場の勾配は長さ 1 なので、向きだけが情報である)。
//
// **勾配は画面の微分 (dfdx / dfdy) からは取らない。** 微分は隣の画素との差分なので、距離場
// の折れ目 (箱の角の外側と内側で式が切り替わる所) をまたぐと勾配の長さが √2 倍まで膨れ、
// 整数に置いた矩形の角の画素が 15% 暗く出る (実測)。式から出す勾配にはその揺れが無い。

/// 距離と勾配の組。
struct FormField {
    float distance;
    float2 gradient;
};

static inline FormField mokume_field(float distance, float2 gradient) {
    FormField field;
    field.distance = distance;
    field.gradient = gradient;
    return field;
}

/// 長さ 1 に揃える。潰れていたら渡された向きにする (0 のままだと被覆が数でなくなる)。
static inline float2 mokume_direction(float2 vector, float2 fallback) {
    float length2 = dot(vector, vector);
    return length2 > 1e-12 ? vector * rsqrt(length2) : fallback;
}

/// 距離場から被覆率を出す。**縁を 1 画素の幅で線形に渡す** (箱フィルタと同じ)。
///
/// 距離は形自身の座標で測っているので、描く画素 1 つが形自身の座標でいくらかを勾配から
/// 出す — 形自身の座標での勾配 n は、描く画素の上では (L⁻¹)ᵀ n になる (L⁻¹ は
/// `inverseRows`。描く画素を基準にしてある)。その長さが「描く画素 1 つあたりに距離が
/// いくら進むか」の逆数である。**出す画素で測ると、描く細かさを下げた面で縁の渡しが
/// 縮む** ([#1488])。
///
/// **見るのは縁 1 本である。** 箱フィルタと一致するのは、画素に縁が 1 本しか入らない
/// ときに限る。帯の両縁が同じ画素に入る (画面で 1 画素より細い) ときは、呼び手が 2 本の
/// 縁を組み合わせる — 輪郭は外縁と内縁の被覆の差、線と点は両縁を見る
/// `mokume_spanCoverage` の積で数える (`mokume_formPaint`・[#1451])。**塗りも同じで**、
/// 1 画素より細い `rect` と楕円の塗りは、この式を通さずに両縁を見る積で数える ([#1477])。
///
/// [#1451]: https://github.com/mokume-metal/mokume/issues/1451
/// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
/// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
static inline float mokume_formCoverage(FormField field, float4 inverseRows) {
    float2 n = field.gradient;
    float2 screen = float2(
        inverseRows.x * n.x + inverseRows.z * n.y,
        inverseRows.y * n.x + inverseRows.w * n.y);
    float pixelsPerUnit = max(length(screen), 1e-6);
    float coverage = 0.5 - field.distance / pixelsPerUnit;
    // **両端に僅かな遊びを持たせる。** 整数に置いた矩形の縁は画素の中心からちょうど 0.5 に
    // 乗り、被覆 0 / 1 の境目そのものになる。頂点の位置は固定小数へ丸められて補間される
    // ので、そこで 1e-4 ほどの揺れが出て、黒いはずの隣の画素が 1/255 だけ染まり、塗り
    // 切ったはずの画素が 254/255 になる (実測)。1/256 の遊びは 1 画素幅の渡しを 0.4% 縮める
    // だけで、目には見えない
    return saturate(coverage * (1.0 + 2.0 * kFormSnap) - kFormSnap);
}

/// 画素 [−0.5, 0.5] と、中心 `center`・半幅 `halfWidth` の帯が重なる長さ (どれも描く画素)。
///
/// **両縁を見る** 1 次元の箱フィルタ。帯が画素より細くても、画素の中に入った分だけを
/// 数える。1 画素より細い線・点・塗りが使う (`mokume_formPaint`)。
static inline float mokume_spanCoverage(float center, float halfWidth) {
    return max(0.0, min(0.5, center + halfWidth) - max(-0.5, center - halfWidth));
}

/// 1 画素より細い楕円の塗りの被覆 ([#1477])。`p` と `radii` は形自身の座標、
/// `unitsPerPixel` は描く画素 1 つが形自身の座標でいくらか。
///
/// 描く画素で細い向きは両縁を見る `mokume_spanCoverage` で、長い向きも両端を見て数え、
/// 掛け合わせる (`rect` の細い塗りと同じ箱フィルタ)。細い向きの半幅は、**画素の中で楕円の
/// 中心にいちばん近い位置**での半幅を取る:
///
/// - 長い向きも 1 画素より短い小さい円・楕円は、画素に中心の高さが入るので半幅は半径
///   のままで、外接する四角の面積 (直径の 2 乗) に比例する。1 画素より細い丸い点
///   (線の枝) と同じ数え方で、`circle(x, y, d)` と太さ d の丸い `point` が同じ量で出る。
///   面積 (π/4 × 直径²) に比例させると、直径 1 の境目で濃さが 2〜3 割跳ぶ
/// - 長い向きが画素で解けている細長い楕円は、画素の列ごとの幅が楕円の形に沿うので、
///   面積に寄る (画素の中のいちばん広い所を取るぶん、`ellipse(x, y, 0.2, 20)` で 5% ほど
///   多い)。2 つの間は連続につながる
///
/// 画素の中心での半幅を取ると、中心を 4 画素の角に置いた小さい円がどの画素でも端に
/// 掛かって消える。`max(r.y, 1e-30)` は速い数学での 0/0 を、`min(…, 1)` と `max(…, 0)` は
/// 負の数の平方根を避けるため。
///
/// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
static inline float mokume_thinEllipseCoverage(float2 p, float2 radii, float2 unitsPerPixel) {
    // 描く画素で細い向きを x に揃える (radii.x / u.x ≤ radii.y / u.y を割らずに比べる)
    bool thinIsX = radii.x * unitsPerPixel.y <= radii.y * unitsPerPixel.x;
    float2 at = thinIsX ? p : p.yx;
    float2 r = thinIsX ? radii : radii.yx;
    float2 u = thinIsX ? unitsPerPixel : unitsPerPixel.yx;
    // 画素の中で、長い向きに楕円の中心へいちばん近い位置
    float nearest = clamp(0.0, at.y - 0.5 * u.y, at.y + 0.5 * u.y);
    float t = min(abs(nearest) / max(r.y, 1e-30), 1.0);
    float halfWidth = r.x * sqrt(max(1.0 - t * t, 0.0));
    return mokume_spanCoverage(at.x / u.x, halfWidth / u.x)
        * mokume_spanCoverage(at.y / u.y, r.y / u.y);
}

/// `a` と `b` の共通部分 (どちらの外側にも出ない形) の距離場。
static inline FormField mokume_intersect(FormField a, FormField b) {
    return a.distance > b.distance ? a : b;
}

/// 原点を中心とする箱の距離場。
static inline FormField mokume_boxField(float2 p, float2 extent) {
    float2 q = abs(p) - extent;
    float2 outside = max(q, 0.0);
    float2 sign2 = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    if (q.x > 0.0 || q.y > 0.0) {
        // 外。いちばん近い角か辺へ向かう向き
        return mokume_field(length(outside), sign2 * mokume_direction(outside, float2(1.0, 0.0)));
    }
    // 内。近い辺の向きへ
    float2 gradient = q.x > q.y ? float2(sign2.x, 0.0) : float2(0.0, sign2.y);
    return mokume_field(max(q.x, q.y), gradient);
}

/// 原点を中心とする楕円の距離場 (近似)。**円なら厳密**に `|p| − r` になる。
///
/// 楕円の厳密な距離は反復が要る。縁の近くで 1 次の精度があれば被覆率には足りる
/// ので、勾配で割った近似を使う。勾配の向きは、縁の法線 (p / r²) で近似する。
static inline FormField mokume_ellipseField(float2 p, float2 radii) {
    float2 q = p / radii;
    float k1 = length(q);
    float2 normal = mokume_direction(p / (radii * radii), float2(1.0, 0.0));
    // 中心そのものは 0/0 になる。いちばん近い縁までの距離を返す
    if (k1 < 1e-6) { return mokume_field(-min(radii.x, radii.y), normal); }
    float k2 = length(q / radii);
    return mokume_field(k1 * (k1 - 1.0) / max(k2, 1e-6), normal);
}

/// `mokume_ellipseField` が返す距離そのものの勾配 (形自身の座標)。`field` はその返り値。
///
/// **返り値の勾配 (`field.gradient`) は縁の法線の向きだけで、長さは 1 に揃えてある。** 距離場
/// そのものの勾配は縁の上では同じだが、縁から離れると長さも向きもずれる — 距離が
/// `k1 (k1 − 1) / k2` という近似で、真の距離ではないからである (円なら厳密で、ずれない)。
/// 輪郭の帯の内縁・外縁は縁から太さの半分だけ離れているので、細長い楕円ほどずれが効く
/// (`mokume_shiftedBySlope`)。`k1`・`k2` は `mokume_ellipseField` のもの、`n` はその法線で、
/// `∇f = (2·k1 − 1) / k1 · n − f / k2 · n / 半径²`。
static inline float2 mokume_ellipseSlope(float2 p, float2 radii, FormField field) {
    float2 q = p / radii;
    float k1 = length(q);
    float k2 = max(length(q / radii), 1e-6);
    // 中心そのものは距離場の勾配が定まらない。法線を返す (`mokume_ellipseField` と同じ扱い)
    if (k1 < 1e-6) { return field.gradient; }
    return field.gradient * ((2.0 * k1 - 1.0) / k1)
        - field.gradient / (radii * radii) * (field.distance / k2);
}

/// 原点から `end` へ引いた線分までの距離場 (符号なし)。
static inline FormField mokume_segmentField(float2 p, float2 end) {
    float h = saturate(dot(p, end) / max(dot(end, end), 1e-12));
    float2 away = p - end * h;
    // **控えの向きも長さ 1 に揃える。** 線分の上に乗った点では `away` が 0 になって控えが
    // 使われるが、`end` は「中心から弧の端まで」なので長さは半径ぶん (この節の他の
    // 距離関数と違い 1 ではない)。長さがそのまま `mokume_formCoverage` の「画素あたり
    // 距離がいくら進むか」に化けるので、渡しが半径の倍だけ間延びし、扇の直線の縁では
    // **輪郭の帯の真ん中の 1 画素だけが薄く抜ける** ([#752](https://github.com/mokume-metal/mokume/issues/752))
    float2 fallback = mokume_direction(float2(-end.y, end.x), float2(0.0, 1.0));
    return mokume_field(length(away), mokume_direction(away, fallback));
}

/// 楕円の扇形 (中心を含む) の距離場。
///
/// **角は媒介変数の角である。** 弧の端は `(rx·cos t, ry·sin t)` の点で、楕円では中心から
/// 見た向き `(cos t, sin t)` とずれる (長い軸の側へ寄る)。三角形の経路 (`arcPoints`) も
/// この点を並べるので、**扇の内外は中心から弧の端へ向かう 2 本の半直線で決める** —
/// 中心から見た角で決めると、楕円でだけ切り口が本当の辺からずれ、塗りも輪郭の弧も
/// 辺の外へはみ出す ([#1448](https://github.com/mokume-metal/mokume/issues/1448))。
///
/// 半平面 2 枚と楕円の `max` では組まない — 掃引が π を越えると半直線の**延長**に
/// 幻の縁が出る (半平面の距離は直線への距離であって半直線への距離ではない)。
/// 2 本の半径は原点から弧の端までの**線分**として距離を取り、楕円の縁は扇の角度の
/// 内側にいるときだけ数える。角の外側は真の距離になるので半径 hw で丸く出る。
static inline FormField mokume_sectorField(float2 p, float2 radii, float start, float sweep) {
    float end = start + sweep;
    // 弧の両端。2 本の辺も内外の判定もこの 2 点から作る
    float2 end1 = radii * float2(cos(start), sin(start));
    float2 end2 = radii * float2(cos(end), sin(end));
    // 中心から弧の端へ向かう半直線を含む半平面。内側 (扇の中) で負になる向きに取る。
    // **符号しか使わない** (距離は下の線分と楕円で画素のまま測る) ので、法線の長さは
    // 揃えない。符号は (x/rx, y/ry) の空間で単位円の扇を切る半平面と同じ — 掃引 t の
    // 扇がそこでも掃引 t なので、π で「かつ / または」を切り替える判定もそのまま使える
    float halfPlane1 = dot(p, float2(end1.y, -end1.x));
    float halfPlane2 = dot(p, float2(-end2.y, end2.x));
    bool inWedge = sweep <= M_PI_F
        ? (halfPlane1 <= 0.0 && halfPlane2 <= 0.0)
        : (halfPlane1 <= 0.0 || halfPlane2 <= 0.0);

    FormField edge1 = mokume_segmentField(p, end1);
    FormField edge2 = mokume_segmentField(p, end2);
    FormField nearest = edge1.distance < edge2.distance ? edge1 : edge2;
    FormField ellipse = mokume_ellipseField(p, radii);
    if (inWedge && abs(ellipse.distance) < nearest.distance) {
        nearest = mokume_field(abs(ellipse.distance), ellipse.gradient);
    }
    bool inside = inWedge && ellipse.distance < 0.0;
    return mokume_field(inside ? -nearest.distance : nearest.distance, nearest.gradient);
}

/// 距離を `amount` だけ外へ広げる (輪郭の帯の外縁・内縁)。勾配は変わらない。
static inline FormField mokume_grown(FormField field, float amount) {
    return mokume_field(field.distance - amount, field.gradient);
}

/// `p` で出した距離場から、`p − shift` での距離場を 1 次の近似で出す。勾配の向きは変わらない。
///
/// **塗りと輪郭を両方持つ楕円で、距離場を 1 回で済ませる**ために使う。輪郭は塗りから
/// 画面で半画素ずらした位置で評価する (頂点関数の説明) が、式をもう 1 度解くと、面を覆う
/// 大きな円 200 個の絵で GPU 時間が 21% 増えた (実測)。
///
/// **誤差の見積もりは、輪郭の内縁の曲率半径 `R` (画素) で `0.25 / R` である。** ずらしの長さは
/// 画面で 0.71 画素以下で、落とすのは 2 次の項 `sᵀ·H·s / 2`。H は評価する位置 (輪郭の帯の
/// 内縁) での 2 階微分で、曲率の逆数になる。かつての説明は「半径 2 画素の円でも 0.13 画素」
/// だったが、これは形の半径で数えていて、**輪郭の太さを引いていない** — 内縁は縁から太さの
/// 半分だけ内側なので、曲率半径は `半径 − 太さの半分` になる。半径 29・太さ 7 の円は 25.5
/// 画素で、見積もりは 0.0098 画素 (実測の被覆率 0.010)。1/255 に収めるには `R` が 64 画素ほど要る。
/// 近似を使ってよいかは、頂点関数が楕円ごとに `mokume_canShiftRing` で決める。
///
/// **この式は円にしか使わない。** 距離場の勾配が縁の外でも内でも長さ 1 で、足す量が法線への
/// 射影で済むのは、円 (真の距離) だけである。円でない楕円は `mokume_shiftedBySlope`。
///
/// **勾配が形の内でも外でも外向きの距離場にしか使えない。** 勾配の向きで距離を足し引き
/// するためである。楕円はそうなっているが、扇形の直線の辺は内側で勾配が扇の中を向く
/// (被覆率は勾配の長さしか読まないので、それで困らなかった)。扇形に使うと直線の辺の
/// 輪郭が逆へずれ、塗りの下に消えた (#1174) — 扇形は式を輪郭の位置で解き直す。
static inline FormField mokume_shifted(FormField field, float2 shift) {
    return mokume_field(field.distance - dot(field.gradient, shift), field.gradient);
}

/// `mokume_shifted` の、円でない楕円の版。`slope` は `p` での距離場そのものの勾配
/// (`mokume_ellipseSlope`)。
///
/// **勾配は、返り値の長さ 1 の向きではなく、距離場そのものの勾配で足す。** 楕円の距離場
/// (`mokume_ellipseField`) は真の距離ではなく、縁から離れると勾配の長さが 1 でなくなる。
/// 長さ 1 の向きで足すと 1 次の項が合わず、縁から太さの半分離れた内縁・外縁に、太さと
/// 形の比に比例する誤差が、上の `0.25 / R` に**足されて**残る。短半径 40・長半径 80・太さ 14
/// では被覆率で 0.11 (`0.25 / R` の 6 倍) になり、内縁の曲率半径をいくら大きくしても
/// 楕円の比と太さ / 短半径が同じなら消えない (1060×530・太さ 7 で 0.0073)。距離場そのものの
/// 勾配で足せば、残るのは 2 次の項だけで、誤差は円と同じ `0.25 / R` に収まる。
///
/// 縁から遠い所 (輪郭の帯が届かない・形の中心の近く) では勾配が膨らむので、足す量は、長さ 1
/// の向きで足した量から、ずらしの 2 成分の絶対値の和の 2 倍 (長さの 2〜2√2 倍) までしか離さ
/// ない。帯の位置には入り込まない。
static inline FormField mokume_shiftedBySlope(FormField field, float2 slope, float2 shift) {
    float along = dot(field.gradient, shift);
    float reach = 2.0 * (abs(shift.x) + abs(shift.y));
    float moved = clamp(dot(slope, shift), along - reach, along + reach);
    return mokume_field(field.distance - moved, field.gradient);
}

/// この画素が出す塗りと輪郭 (どちらも被覆率を掛けた乗算済みの色)。
struct FormPaint {
    float4 fill;
    float4 stroke;
    float fillCoverage;
    float strokeCoverage;
};

/// 距離関数で塗りと輪郭の被覆率を出す。**下地は見ない。**
///
/// 形を決める仕事はここ 1 本にし、入口ごとに式を写さない。
///
/// `layered` は、呼ぶ側が塗りと輪郭を**先に重ねてから 1 回置く** (`mokume_formLayered`) か。
/// 真のときだけ、次の 2 つを掛ける (どちらも下の説明)。呼ぶ側の定数なので、使わない側の式は
/// 原稿から消える。
///
/// - 継ぎ目の割り戻しを、塗りの被覆率に掛ける
/// - 楕円の輪郭を、誤差が 1/255 に収まるときだけ、塗りの距離場から 1 次の近似でずらす
///
/// 偽なら、塗りだけの形と輪郭だけの形を別々に出したのと同じ被覆率になる。
///
/// **入口によって違うのは割り戻しの分だけで、輪郭の形はどの入口でも同じである。** 楕円の
/// 輪郭の被覆率は、塗りの有無・混ぜ方によらず、輪郭だけの楕円と 1/255 以内で一致する
/// (近似でずらすのは誤差の見積もりが収まる楕円だけで、ほかは式を輪郭の位置で解き直す —
/// `mokume_canShiftRing`・[#1820](https://github.com/mokume-metal/mokume/issues/1820))。
///
/// `replacing` は、呼ぶ側が**置き換える**列か (`layered` のときだけ読む)。割り戻しで帯の下の
/// 塗りをどれだけ見せるかが変わる — 重ねる列は輪郭が透ける分だけ、置き換える列は少しも
/// 見せない (割り戻しの説明)。これも呼ぶ側の定数である。
static inline FormPaint mokume_formPaint(
    FormFragmentIn in, constant FormInstance *instances, bool layered, bool replacing)
{
    FormInstance form = instances[in.instance];
    float2 p = in.local;
    // 輪郭と線を評価する位置 (頂点関数の説明)。塗りは `p` のまま
    float2 q = p - in.strokeShift;
    float halfWeight = form.size.z;
    uint kind = form.meta.x;
    // 描く画素 1 つが形自身の座標でいくらか。x が形自身の x の向き、y が y の向きで、
    // `inverseRows` の行ノルムになる (`mokume_formCoverage` の説明で n を軸に取ったもの)。
    // 線では x が長さの向き、y が太さの向きになる。描く画素で測るので、細かさ 0.5 の面の
    // 太さ 1 の線は、描く画素で太さ 0.5 の線として線の細い枝を通る (#1488)
    float2 unitsPerPixel = float2(length(in.inverseRows.xy), length(in.inverseRows.zw));

    // 塗りの距離場と、輪郭の**外縁**・**内縁**の距離場。輪郭は「外縁の内側で内縁の外側」
    FormField fill = mokume_field(1e6, float2(1.0, 0.0));
    FormField outer = fill;
    FormField inner = fill;
    // 画面で 1 画素より細い線と点は、距離場を通さずに被覆を出す (線の枝の説明)
    bool isThinLine = false;
    float thinLineCoverage = 0.0;
    // 画面で 1 画素より細い塗りも同じ (`rect` の塗りの説明)
    bool isThinFill = false;
    float thinFillCoverage = 0.0;
    if (kind == kFormRect) {
        float2 extent = form.size.xy;
        if (kFormHasFill) {
            fill = mokume_boxField(p, extent);
            if (kFormHasThinFill
                && any(2.0 * extent * (1.0 + 2.0 * kFormSnap) < unitsPerPixel)) {
                // **画面で 1 画素より細い塗りは、両縁を見る 1 次元の被覆の積で数える**
                // ([#1477](https://github.com/mokume-metal/mokume/issues/1477))。
                // 距離場は縁 1 本しか持たないので、帯の両縁が同じ画素に入ると向こう側の縁の
                // 欠けを引けない — 幅 0.1・高さ 20 の `rect` (面積 2) の和が、帯の中心を画素の
                // 中心に置くと 11.0、画素の境目に置くと 1.86 と、置く位置で 6 倍揺れていた。
                // 塗りは寄せない (ADR-0039 決定 2) ので `q` ではなく `p` で数える。
                //
                // 数え方も境目も、1 画素より細い線の枝と同じにする。細い向きと長い向きの
                // それぞれで画素と帯が重なる長さを取って掛け合わせる (箱フィルタ) ので、濃さは
                // 置く位置によらず面積に比例する。回した形も行ノルムで画素へ直すので同じ濃さで
                // 出る (剪断と縦横比の違う拡大では近似)。
                //
                // **1/256 の遊び (`mokume_formCoverage`) は掛けない。** 両縁に掛けると細い帯
                // ほど効きが大きくなる (幅 0.05 の帯が画素の境目をまたぐと 15% 足りなくなる)。
                //
                // **境目は 1 画素ちょうどではなく 256/258 画素に置く** (線の枝と同じ理由)。
                // 幅 1 の塗りは、回しても逆行列の行ノルムの丸め (1e-7 ほど) で境目をまたが
                // ない。それより太い塗りは縁 1 本の式のままで、絵は 1 ビットも変わらない。
                //
                // **細い塗りを含まない列では、枝ごと原稿から外す** (`kFormHasThinFill`)
                isThinFill = true;
                thinFillCoverage =
                    mokume_spanCoverage(p.x / unitsPerPixel.x, extent.x / unitsPerPixel.x)
                    * mokume_spanCoverage(p.y / unitsPerPixel.y, extent.y / unitsPerPixel.y);
            }
        }
        if (kFormHasStroke) {
            // 角の形は外縁だけが持つ。内縁は帯が重なって必ず直角 (三角形のときと同じ)
            if (form.meta.z == kFormJoinRound) {
                outer = mokume_grown(mokume_boxField(q, extent), halfWeight);
            } else {
                outer = mokume_boxField(q, extent + halfWeight);
                if (form.meta.z == kFormJoinBevel) {
                    // 尖りを 45° で削ぐ。削ぐ線は角から線幅の半分だけ離れた所を通る
                    float chamfer =
                        (abs(q.x) + abs(q.y) - (extent.x + extent.y + halfWeight * M_SQRT2_F))
                        * M_SQRT1_2_F;
                    float2 gradient = float2(q.x < 0.0 ? -M_SQRT1_2_F : M_SQRT1_2_F,
                                             q.y < 0.0 ? -M_SQRT1_2_F : M_SQRT1_2_F);
                    outer = mokume_intersect(outer, mokume_field(chamfer, gradient));
                }
            }
            // 線幅が形より太いと半幅が負になり、内縁は「どこにも無い」(被覆 0) になる —
            // 帯が重なって全部塗られる、三角形のときと同じ絵
            inner = mokume_boxField(q, extent - halfWeight);
        }
    } else if (kind == kFormEllipse) {
        // 塗りと輪郭は評価する位置が違う。**両方を持つ列では、輪郭の側を塗りの距離場から 1 次の
        // 近似でずらして、式を 1 回で済ませる** (`mokume_shifted`・`mokume_shiftedBySlope`)。
        // ただし**近似でずらしてよいのは、誤差の見積もりが 1/255 の半分に収まる楕円だけ**で、頂点関数が
        // 楕円ごとに決める (`mokume_canShiftRing`・`ringFromFill`)。内縁の曲率半径が小さい楕円
        // (半径 29・太さ 7 の円でも) は、輪郭しか持たない列と同じく式を輪郭の位置で解き直す。
        // 近似でずらす誤差は円で 0.25 / R (R: 内縁の曲率半径・画素) で、これを許す範囲に収める
        // ([#1820](https://github.com/mokume-metal/mokume/issues/1820))。
        //
        // **近似でずらすのは、塗りと輪郭を先に重ねる断片だけである** (`layered`)。下地を読む
        // 断片は、塗りだけの形の上に輪郭だけの形を重ねたのと同じ絵を出す約束 (下の割り戻しの
        // 説明) なので、どの楕円も輪郭の位置で解き直す。近似のままだと、輪郭の内縁に 1 次の
        // 近似の誤差 (半径 29 の円で被覆率 0.01 ほど) が残り、加算で表示の 1 段を越えた
        // ([#1643](https://github.com/mokume-metal/mokume/issues/1643))
        if (kFormHasFill) {
            fill = mokume_ellipseField(p, form.size.xy);
            // 1 画素より細い楕円の塗りは、`rect` の細い塗りと同じ境目で、両縁を見る積で
            // 数える (`mokume_thinEllipseCoverage`)。**距離場は細くても解く** — 輪郭の側が
            // それを読む (下の `mokume_shifted`・`mokume_shiftedBySlope`。塗りと輪郭を先に重ねる断片だけ)
            if (kFormHasThinFill
                && any(2.0 * form.size.xy * (1.0 + 2.0 * kFormSnap) < unitsPerPixel)) {
                isThinFill = true;
                thinFillCoverage = mokume_thinEllipseCoverage(p, form.size.xy, unitsPerPixel);
            }
        }
        if (kFormHasStroke) {
            FormField ring;
            if (layered && kFormHasFill && in.ringFromFill == 2) {
                ring = mokume_shifted(fill, in.strokeShift);
            } else if (layered && kFormHasFill && in.ringFromFill == 1) {
                ring = mokume_shiftedBySlope(
                    fill, mokume_ellipseSlope(p, form.size.xy, fill), in.strokeShift);
            } else {
                ring = mokume_ellipseField(q, form.size.xy);
            }
            outer = mokume_grown(ring, halfWeight);
            inner = mokume_grown(ring, -halfWeight);
        }
    } else if (kind == kFormArc) {
        // 扇形は 1 次の近似でずらせない (`mokume_shifted` の説明)。塗りと輪郭で式を別々に解く
        if (kFormHasFill) { fill = mokume_sectorField(p, form.size.xy, form.offset.z, form.offset.w); }
        if (kFormHasStroke) {
            FormField ring = mokume_sectorField(q, form.size.xy, form.offset.z, form.offset.w);
            outer = mokume_grown(ring, halfWeight);
            inner = mokume_grown(ring, -halfWeight);
        }
    } else if (kFormHasStroke) {
        // 線。塗りは持たず、線そのものの距離場を輪郭の外縁として使う
        float halfLength = form.size.x;
        // 描く画素 1 つが形自身の座標でいくらか (`unitsPerPixel`) は、x が長さの向き、
        // y が太さの向きになる
        if (2.0 * halfWeight * (1.0 + 2.0 * kFormSnap) < unitsPerPixel.y) {
            // **画面で 1 画素より細い線と点は、両縁を見る 1 次元の被覆の積で数える。**
            // 距離場は縁 1 本しか持たないので、帯の両縁が同じ画素に入ると、向こう側の縁の
            // 欠けを引けない — 線は画素の中心に乗る約束 (ADR-0039 決定 2) なので、整数の
            // 座標では帯の中心が画素の中心に来て、太さ 0.1 の線がその 1 画素を 0.55 で
            // 塗っていた (半端な座標の 5.9 倍・#1451)。
            //
            // 太さの向きと長さの向きのそれぞれで画素と帯が重なる長さを取り、掛け合わせる
            // (箱フィルタ)。濃さは置く位置によらず太さに比例し、点は面積 (太さの 2 乗) に
            // 比例する。丸い端はここでは出っ張る端と同じ四角に数える — 違いは画素 1 つの
            // 中に収まり、太さ 1 の丸い点 (下の枝で和 1.0〜1.17) とも続く。回した線も
            // 行ノルムで画素へ直すので同じ濃さで出る (剪断と縦横比の違う拡大では近似)。
            //
            // **1/256 の遊び (`mokume_formCoverage`) は掛けない。** 遊びは縁が画素の境目に
            // 乗るときの揺れを消すためのもので、両縁に掛けると細い帯ほど効きが大きくなる
            // (太さ 0.1 の帯を画素の境目に置くと 7%・太さ 0.05 で 15% 足りなくなる)。
            //
            // **境目は 1 画素ちょうどではなく 256/258 画素に置く。** 遊びを込めると、それより
            // 太い帯では向こう側の縁が画素の被覆に入らない (輪郭の差と積が一致するのと同じ
            // 境目・下の説明) ので、縁 1 本の距離場のままで両縁を見たのと 1 ビットも違わない。
            // 1 画素ちょうどに置くと、既定の太さ 1 で引いた斜めの線が、逆行列の行ノルムの
            // 丸め (1e-7 ほど) で境目の両側へ散って絵が動く。太さ 256/258 画素以上はこの枝を
            // 通らないので、絵は 1 ビットも変わらない
            float reach = halfLength + (form.meta.y == kFormCapSquare ? 0.0 : halfWeight);
            isThinLine = true;
            thinLineCoverage =
                mokume_spanCoverage(q.y / unitsPerPixel.y, halfWeight / unitsPerPixel.y)
                * mokume_spanCoverage(q.x / unitsPerPixel.x, reach / unitsPerPixel.x);
        } else if (form.meta.y == kFormCapRound) {
            // カプセル: 線分からの距離 − 太さの半分
            float2 away = float2(q.x < 0.0 ? min(q.x + halfLength, 0.0) : max(q.x - halfLength, 0.0), q.y);
            outer = mokume_field(
                length(away) - halfWeight, mokume_direction(away, float2(0.0, 1.0)));
        } else if (form.meta.y == kFormCapSquare) {
            outer = mokume_boxField(q, float2(halfLength, halfWeight));
        } else {
            outer = mokume_boxField(q, float2(halfLength + halfWeight, halfWeight));
        }
        // 内縁は無い (被覆 0 にするため、必ず外側に置いたまま)。縁 1 本の距離場で足りるのは
        // 太さが (遊びを込めて) 1 画素以上のときで、それより細い線と点は上の枝で両縁を数える
    }

    FormPaint paint;
    paint.fillCoverage = 0.0;
    paint.strokeCoverage = 0.0;
    // **線と点は塗りを持たない。** 旗で列が切れるので塗りのある列には混ざらないが、
    // 種別は列の中で混ざるので、ここで名指しして外す
    if (kFormHasFill && kind != kFormLine) {
        // 1 画素より細い塗りだけが別に数えた値を使う (`rect` の塗りの説明)。細い塗りを
        // 含まない列では `isThinFill` が常に偽なので、選ぶ式も原稿から消える
        paint.fillCoverage =
            isThinFill ? thinFillCoverage : mokume_formCoverage(fill, in.inverseRows);
    }
    if (kFormHasStroke) {
        float outerCoverage = mokume_formCoverage(outer, in.inverseRows);
        float innerCoverage = mokume_formCoverage(inner, in.inverseRows);
        // **帯の被覆は、外縁の被覆 − 内縁の被覆。** 縁は画素の幅では平行とみなせるので、
        // 帯 = (外縁の内) − (内縁の内) で、画素の中の面積も引き算になる。2 つを掛け合わせる
        // 式 (外縁の内 × 内縁の外) は 2 つが画素の中で無関係に散らばっているとみなすので、
        // 両縁が同じ画素に入る 1 画素より細い帯では内縁の欠けを引き切れず、太さ 0.1 の縁の
        // 和が置く位置で 0.09〜0.30 に揺れていた (#1451)。
        //
        // 1 画素以上の帯では、内縁が画素に掛かるときは外縁が画素を覆い切っている (外縁の
        // 被覆がちょうど 1) ので、差と積は 1 ビットも違わない — 遊び (1/256) を込めて、画面の
        // 太さ 256/258 ≈ 0.9923 画素以上で成り立つ。線は内縁を持たない (被覆 0) ので外縁の
        // 被覆がそのまま残り、1 画素より細い線と点だけが別に数えた値を使う
        paint.strokeCoverage =
            isThinLine ? thinLineCoverage : max(0.0, outerCoverage - innerCoverage);
        if (layered && kFormHasFill && kind != kFormLine) {
            // **塗りと輪郭の継ぎ目で下地を漏らさない。** 2 つの被覆率をそのまま重ねると、
            // 画素の中で「塗り」と「輪郭の帯」が互いに無関係に散らばっているとみなすことに
            // なり、2 つが接する画素 (塗りの縁が帯の内縁と揃う側) で下地が透ける — 輪郭を
            // 画面で半画素寄せる約束 (ADR-0039 決定 2) では、塗りと帯の中心が半画素違うので
            // 片側に必ず現れる (太さ 1 で最悪 25%・太さ 2 で 12% 暗くなった)。
            //
            // そこで、画素の中で塗りと帯が**重なる割合**を見積もる。縁が画素の幅では平行と
            // みなせるので、平行な半平面どうしの共通部分の被覆率は小さいほうになる:
            // 塗り ∩ 帯 = (塗り ∩ 外縁) − (塗り ∩ 内縁)。塗りが見える重みは「帯の外の塗り
            // は全部、帯の下の塗りは輪郭が透ける分だけ」で、それを重ねる式 (輪郭 over 塗り)
            // で割り戻したものを塗りの被覆率とする。塗りだけ・輪郭だけの列は旗が外すので、
            // 絵は 1 ビットも変わらない。
            //
            // **割り戻すのは、塗りと輪郭を先に重ねる断片だけである** (`layered`)。割り戻しは
            // 「輪郭を塗りの上に重ねる (over)」前提の式で、下地を読む断片 (`mokume_formFragment`)
            // は塗りと輪郭を別々に下地と混ぜる。そこへ持ち込むと、不透明な輪郭の帯の内側半分
            // で分母 (帯の透ける割合) が 0 になって塗りが消え、加算で塗りが足されなかった
            // ([#1643](https://github.com/mokume-metal/mokume/issues/1643))。別々に混ぜる
            // 断片は割り戻す前の被覆率を使い、塗りだけの形の上に輪郭だけの形を重ねたのと
            // 同じ絵を出す。
            //
            // **その代わり、下地を読む列には継ぎ目の漏れが戻る。** 被覆率について線形な
            // `.add` / `.subtract` を除き、分けて重ねた絵 (三角形の経路も同じ) が持つ漏れを
            // そのまま持つ。`.lightest` / `.screen` の白い円で、太さ 1 で最悪 24%・太さ 2 で
            // 12% 暗い。「分けて重ねた絵と同じ」と「継ぎ目で漏れない」は線形でない混ぜ方では
            // 両立せず、#1643 は前者を取った。どちらを約束にするかは
            // [#1818](https://github.com/mokume-metal/mokume/issues/1818)
            //
            // **置き換える列は、帯の下の塗りを少しも見せない** (`replacing`)。画素を塗りだけ
            // `f − o`・重なり `o`・帯だけ `s − o`・どちらでもない所の 4 つの面積に分け、
            // それぞれを混ぜた色を面積で足す — 塗りと輪郭を両方持つ形の 1 画素の約束である
            // ([#1867](https://github.com/mokume-metal/mokume/issues/1867) 決定 1)。重ねる
            // (over) で解くと重なりには「輪郭 over 塗り」が入り、上の重みになる。置き換えで
            // 解くと重なりには後に置いた輪郭だけが入るので、塗りが見える重みは `f − o` で、
            // 置く色は `S·s + F·(f − o)` になる。三角形の経路 (塗りの三角形の上に輪郭の
            // 三角形を置き換える) と、塗りだけ → 輪郭だけの順に分けて描いた絵が帯に置く色
            // と同じである。かつては置き換える列も重ねる重みで割り戻していたので、半透明の
            // 輪郭の帯の内側半分に塗りが透け、透明な地では α が輪郭の不透明度を越えて
            // 1.0 まで埋まった ([#1819](https://github.com/mokume-metal/mokume/issues/1819))。
            // 不透明な輪郭では 2 つの重みが同じになり、絵は 1 ビットも変わらない
            float overlap = max(
                0.0,
                min(paint.fillCoverage, outerCoverage) - min(paint.fillCoverage, innerCoverage));
            float strokeAlpha = form.stroke.a;
            float visible = paint.fillCoverage - overlap * (replacing ? 1.0 : strokeAlpha);
            float behind = 1.0 - strokeAlpha * paint.strokeCoverage;
            paint.fillCoverage = behind > 1e-4 ? saturate(visible / behind) : 0.0;
        }
    }
    paint.fill = form.fill * paint.fillCoverage;
    paint.stroke = form.stroke * paint.strokeCoverage;
    return paint;
}

/// 塗りと輪郭を**先に重ねた**、この画素 1 つぶんの色 (乗算済み)。
///
/// 重ねる (`over`) は結合的なので、下地へ 2 回置くのと「先に重ねてから 1 回置く」のは
/// 同じ式である。**下地を読まない入口はこちらを使う** — 下地に触れるのが 1 回だけに
/// なるので、混ぜるのを固定機能のブレンドへ渡せる。置き換える列も同じ式で置くが、
/// 結合則に頼るのではなく、塗りの被覆率を置き換えの重みで割り戻してある
/// (`mokume_formPaint` の `replacing`)。
static inline float4 mokume_formLayered(FormPaint paint) {
    return paint.stroke + paint.fill * (1.0 - paint.stroke.a);
}

/// 形の外の余白か (1 画素も触らない — 置き換える混ぜ方で余白が書かれないように)。
static inline bool mokume_formIsBlank(FormPaint paint) {
    return paint.fillCoverage <= 0.0 && paint.strokeCoverage <= 0.0;
}

/// 基本図形の断片。**下地を読み、混ぜ方で分岐する。**
///
/// 使うのは固定機能のブレンドで表せない混ぜ方の列だけである
/// (一覧は `ShapePipeline.BlendStates` の doc)。
fragment float4 mokume_formFragment(
    FormFragmentIn in [[stage_in]],
    constant uint &mode [[buffer(2)]],
    constant FormInstance *instances [[buffer(10)]],
    float4 destination [[color(0)]])
{
    FormPaint paint = mokume_formPaint(in, instances, false, false);
    if (mokume_formIsBlank(paint)) {
        discard_fragment();
        return destination;
    }
    // **塗りの上に輪郭**の順で、それぞれ下地と混ぜる — 塗りの三角形の上に輪郭の
    // 三角形を置いていたときと同じ順序・同じ式。被覆 0 の側は掛けない
    // (乗算を戻して掛け直す往復で最下位ビットが動くのを避ける)
    float4 result = destination;
    if (paint.fillCoverage > 0.0) { result = mokume_composite(paint.fill, result, mode); }
    if (paint.strokeCoverage > 0.0) { result = mokume_composite(paint.stroke, result, mode); }
    return result;
}

/// 基本図形の断片 (重ねる列)。**下地を読まず、捨てもしない。**
///
/// 混ぜるのは固定機能のブレンドで、乗算済みの `source + destination × (1 − source.a)`
/// を計算する ([#758])。**形の外の余白では出す色が 0 になり、式は下地をそのまま返す** —
/// だから捨てる必要が無い (捨てないほうが速い。実測 7.4 ms / 8.2 ms・[#771])。
///
/// [#758]: https://github.com/mokume-metal/mokume/issues/758
/// [#771]: https://github.com/mokume-metal/mokume/issues/771
fragment float4 mokume_formFragmentBlend(
    FormFragmentIn in [[stage_in]],
    constant FormInstance *instances [[buffer(10)]])
{
    return mokume_formLayered(mokume_formPaint(in, instances, true, false));
}

/// 基本図形の断片 (置き換える列)。**下地を読まないが、余白は捨てる。**
///
/// 置き換える混ぜ方は下地を見ないので読む必要は無い。ただし**書けば下地が消える**ので、
/// 形の外の余白は捨てなければならない。
///
/// **置き換えるのは部品の単位である** ([#1819])。輪郭の帯では、塗りの上に輪郭を置き換えた
/// のと同じく輪郭だけが残り、下の塗りは輪郭が半透明でも透けない。置く色は 1 つの式
/// (`mokume_formLayered`) だが、塗りの被覆率を置き換えの重みで割り戻してある
/// (`mokume_formPaint` の `replacing`) ので、`S·s + F·(f − o)` になる — 三角形の経路と、
/// 塗りだけ → 輪郭だけの順に分けて描いた絵が帯に置く色である。
///
/// [#1819]: https://github.com/mokume-metal/mokume/issues/1819
fragment float4 mokume_formFragmentReplace(
    FormFragmentIn in [[stage_in]],
    constant FormInstance *instances [[buffer(10)]])
{
    FormPaint paint = mokume_formPaint(in, instances, true, true);
    if (mokume_formIsBlank(paint)) {
        discard_fragment();
        return float4(0.0);
    }
    return mokume_formLayered(paint);
}
