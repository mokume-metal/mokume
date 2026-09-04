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

/// 列ごとに変わらないもの。**立体は先頭の行列だけを読む**ので、後ろに足しても効かない。
struct FlatFrame {
    float4x4 projection;
    /// 輪郭の頂点が始まる番号。**ここから後ろが輪郭**で、手前が塗りである。
    /// 畳めない列は塗りしか無い扱い (置き場所の 2 色がどちらも白なので同じ)。
    uint strokeStart;
};

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant FlatInstance *instances [[buffer(10)]])
{
    ShapeVertex vertex_in = vertices[index];
    FlatInstance placement = instances[instance];

    // **形自身の座標を、置き場所の変換で描画先の座標へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、畳めない頂点も同じ経路を通る
    float2 placed = placement.linear.xy * vertex_in.position.x
        + placement.linear.zw * vertex_in.position.y + placement.offset.xy;

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
    constant float4x4 &viewProjection [[buffer(1)]],
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
    out.position = viewProjection * world;
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

// 種別・端・折れ目・旗の番号。Swift 側の FormInstance と対応する
constant uint kFormRect = 0;
constant uint kFormEllipse = 1;
constant uint kFormArc = 2;
constant uint kFormLine = 3;
constant uint kFormCapRound = 0;
constant uint kFormCapSquare = 1;
constant uint kFormCapProject = 2;
constant uint kFormJoinMiter = 0;
constant uint kFormJoinBevel = 1;
constant uint kFormJoinRound = 2;
constant uint kFormFills = 1;
constant uint kFormStrokes = 2;

/// 縁を滑らかにする余白 (画素)。被覆が 0 になるのは縁から 0.5 画素なので、微分の
/// 揺れを見込んで 2 画素取る
constant float kFormMargin = 2.0;

/// 被覆率の両端の遊び (`mokume_formCoverage`)。
constant float kFormSnap = 1.0 / 256.0;

struct FormFragmentIn {
    float4 position [[position]];
    /// 形自身の座標での位置。距離関数はこの座標で評価する
    float2 local;
    /// 描画先 → 形自身の座標の 2x2 (逆行列) の 2 行。xy が 1 行目、zw が 2 行目。
    /// 形自身の座標での勾配を画面の勾配へ写すのに使う (`mokume_formCoverage`)
    float4 inverseRows [[flat]];
    /// 塗りを評価する位置のずらし (形自身の座標)。矩形だけが持つ (下の説明)
    float2 fillShift [[flat]];
    uint instance [[flat]];
};

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

    // 縁の余白は**画面の画素**で測る。形自身の座標では、逆行列の行ノルムぶんになる —
    // 画面で半径 2 画素の円は、形自身の座標ではその楕円の外接する箱に収まる
    extent += kFormMargin * float2(length(inverseRows.xy), length(inverseRows.zw));

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
    out.inverseRows = inverseRows;
    // **矩形の塗りは半画素ぶん戻して置く。** 整数の座標は画素の中心を指すので、そのまま
    // 縁に使うと縁の画素が半分だけ覆われ、整数に置いた矩形が滲む。縁を画素の境目へ寄せる
    // と、`rect(10, 20, 4, 8)` は三角形で描いていたときと同じ 4x8 画素ちょうどを塗る
    // (字形と画像の四角も同じ理由で戻している — `Canvas.appendGlyphQuad`)。
    //
    // 戻すのは**縁に基準を置く形の塗り**だけである。円・楕円・扇形は中心に基準があるので
    // 戻すと中心が半画素ずれる。輪郭は縁の上に中心を持つ帯なので、これも戻さない (太さ 1
    // の線が整数の座標で 1 画素に収まるのはそのため)。ずらしは画面の半画素を形自身の座標へ
    // 逆行列で写したもの — 拡大しても回しても画面上で半画素になる
    float shift = form.meta.x == kFormRect ? 0.5 : 0.0;
    out.fillShift = shift * float2(inverseRows.x + inverseRows.y, inverseRows.z + inverseRows.w);
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
/// 距離は形自身の座標で測っているので、画面の 1 画素が形自身の座標でいくらかを勾配から
/// 出す — 形自身の座標での勾配 n は、画面では (L⁻¹)ᵀ n になる。その長さが「画面の
/// 1 画素あたりに距離がいくら進むか」の逆数である。
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

/// 原点から `end` へ引いた線分までの距離場 (符号なし)。
static inline FormField mokume_segmentField(float2 p, float2 end) {
    float h = saturate(dot(p, end) / max(dot(end, end), 1e-12));
    float2 away = p - end * h;
    return mokume_field(length(away), mokume_direction(away, float2(-end.y, end.x)));
}

/// 楕円の扇形 (中心を含む) の距離場。
///
/// 半平面 2 枚と楕円の `max` では組まない — 掃引が π を越えると半直線の**延長**に
/// 幻の縁が出る (半平面の距離は直線への距離であって半直線への距離ではない)。
/// 2 本の半径は原点から弧の端までの**線分**として距離を取り、楕円の縁は扇の角度の
/// 内側にいるときだけ数える。角の外側は真の距離になるので半径 hw で丸く出る。
static inline FormField mokume_sectorField(float2 p, float2 radii, float start, float sweep) {
    float end = start + sweep;
    float2 direction1 = float2(cos(start), sin(start));
    float2 direction2 = float2(cos(end), sin(end));
    // 2 本の半直線を含む半平面。内側 (扇の中) で負になる向きに取る
    float halfPlane1 = dot(p, float2(direction1.y, -direction1.x));
    float halfPlane2 = dot(p, float2(-direction2.y, direction2.x));
    bool inWedge = sweep <= M_PI_F
        ? (halfPlane1 <= 0.0 && halfPlane2 <= 0.0)
        : (halfPlane1 <= 0.0 || halfPlane2 <= 0.0);

    FormField edge1 = mokume_segmentField(p, radii * direction1);
    FormField edge2 = mokume_segmentField(p, radii * direction2);
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

/// 基本図形の断片。距離関数で塗りと輪郭の被覆率を出し、下地と混ぜる。
fragment float4 mokume_formFragment(
    FormFragmentIn in [[stage_in]],
    constant uint &mode [[buffer(2)]],
    constant FormInstance *instances [[buffer(10)]],
    float4 destination [[color(0)]])
{
    FormInstance form = instances[in.instance];
    float2 p = in.local;
    float halfWeight = form.size.z;
    uint kind = form.meta.x;
    bool fills = (form.meta.w & kFormFills) != 0;
    bool strokes = (form.meta.w & kFormStrokes) != 0;

    // 塗りの距離場と、輪郭の**外縁**・**内縁**の距離場。輪郭は「外縁の内側で内縁の外側」
    FormField fill = mokume_field(1e6, float2(1.0, 0.0));
    FormField outer = fill;
    FormField inner = fill;
    if (kind == kFormRect) {
        float2 extent = form.size.xy;
        // 塗りだけ半画素戻す (頂点関数の説明)。輪郭は戻さない
        fill = mokume_boxField(p + in.fillShift, extent);
        // 角の形は外縁だけが持つ。内縁は帯が重なって必ず直角 (三角形のときと同じ)
        if (form.meta.z == kFormJoinRound) {
            outer = mokume_grown(mokume_boxField(p, extent), halfWeight);
        } else {
            outer = mokume_boxField(p, extent + halfWeight);
            if (form.meta.z == kFormJoinBevel) {
                // 尖りを 45° で削ぐ。削ぐ線は角から線幅の半分だけ離れた所を通る
                float chamfer = (abs(p.x) + abs(p.y) - (extent.x + extent.y + halfWeight * M_SQRT2_F))
                    * M_SQRT1_2_F;
                float2 gradient = float2(p.x < 0.0 ? -M_SQRT1_2_F : M_SQRT1_2_F,
                                         p.y < 0.0 ? -M_SQRT1_2_F : M_SQRT1_2_F);
                outer = mokume_intersect(outer, mokume_field(chamfer, gradient));
            }
        }
        // 線幅が形より太いと半幅が負になり、内縁は「どこにも無い」(被覆 0) になる —
        // 帯が重なって全部塗られる、三角形のときと同じ絵
        inner = mokume_boxField(p, extent - halfWeight);
    } else if (kind == kFormEllipse) {
        fill = mokume_ellipseField(p, form.size.xy);
        outer = mokume_grown(fill, halfWeight);
        inner = mokume_grown(fill, -halfWeight);
    } else if (kind == kFormArc) {
        fill = mokume_sectorField(p, form.size.xy, form.offset.z, form.offset.w);
        outer = mokume_grown(fill, halfWeight);
        inner = mokume_grown(fill, -halfWeight);
    } else {
        // 線。塗りは持たず、線そのものの距離場を輪郭の外縁として使う
        float halfLength = form.size.x;
        if (form.meta.y == kFormCapRound) {
            // カプセル: 線分からの距離 − 太さの半分
            float2 away = float2(p.x < 0.0 ? min(p.x + halfLength, 0.0) : max(p.x - halfLength, 0.0), p.y);
            outer = mokume_field(
                length(away) - halfWeight, mokume_direction(away, float2(0.0, 1.0)));
        } else if (form.meta.y == kFormCapSquare) {
            outer = mokume_boxField(p, float2(halfLength, halfWeight));
        } else {
            outer = mokume_boxField(p, float2(halfLength + halfWeight, halfWeight));
        }
        // 内縁は無い (被覆 0 にするため、必ず外側に置いたまま)
        fills = false;
    }

    float fillCoverage = fills ? mokume_formCoverage(fill, in.inverseRows) : 0.0;
    float strokeCoverage = strokes
        ? mokume_formCoverage(outer, in.inverseRows)
            * (1.0 - mokume_formCoverage(inner, in.inverseRows))
        : 0.0;

    // 形の外の余白は 1 画素も触らない (置き換える混ぜ方で余白が書かれないように)
    if (fillCoverage <= 0.0 && strokeCoverage <= 0.0) {
        discard_fragment();
        return destination;
    }

    // **置き換える混ぜ方だけは、塗りと輪郭を先に重ねてから置く。** 順に置き換えると
    // 輪郭の内縁で「輪郭 × 被覆」だけが残り、塗りとの継ぎ目に 1 画素の筋が出る
    float4 fillColor = form.fill * fillCoverage;
    float4 strokeColor = form.stroke * strokeCoverage;
    if (mode == kReplace) {
        return strokeColor + fillColor * (1.0 - strokeColor.a);
    }
    // それ以外は**塗りの上に輪郭**の順で、それぞれ下地と混ぜる — 塗りの三角形の上に
    // 輪郭の三角形を置いていたときと同じ順序・同じ式。被覆 0 の側は掛けない
    // (乗算を戻して掛け直す往復で最下位ビットが動くのを避ける)
    float4 result = destination;
    if (fillCoverage > 0.0) { result = mokume_composite(fillColor, result, mode); }
    if (strokeCoverage > 0.0) { result = mokume_composite(strokeColor, result, mode); }
    return result;
}
