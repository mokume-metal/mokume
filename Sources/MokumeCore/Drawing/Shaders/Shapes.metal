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
    /// 1 なら**輪郭の頂点**。頂点関数が画面で半画素寄せる (Swift 側の `SolidVertex` を参照)
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
    out.position.xy += vertex_in.stroke * frame.strokeShift.xy * out.position.w;
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

/// `p` で出した距離場から、`p − shift` での距離場を 1 次の近似で出す。勾配は変わらない。
///
/// **塗りと輪郭を両方持つ楕円で、距離場を 1 回で済ませる**ために使う。輪郭は塗りから
/// 画面で半画素ずらした位置で評価する (頂点関数の説明) が、式をもう 1 度解くと、面を覆う
/// 大きな円 200 個の絵で GPU 時間が 21% 増えた (実測)。ずらしは画素の 0.7 倍以下なので、
/// 近似の誤差は曲率に比例して、半径 2 画素の円でも 0.13 画素を超えない。
///
/// **勾配が形の内でも外でも外向きの距離場にしか使えない。** 勾配の向きで距離を足し引き
/// するためである。楕円はそうなっているが、扇形の直線の辺は内側で勾配が扇の中を向く
/// (被覆率は勾配の長さしか読まないので、それで困らなかった)。扇形に使うと直線の辺の
/// 輪郭が逆へずれ、塗りの下に消えた (#1174) — 扇形は式を輪郭の位置で解き直す。
static inline FormField mokume_shifted(FormField field, float2 shift) {
    return mokume_field(field.distance - dot(field.gradient, shift), field.gradient);
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
/// 下地を読む入口と読まない入口が同じ形を出すよう、形を決める仕事はここ 1 本にする。
static inline FormPaint mokume_formPaint(
    FormFragmentIn in, constant FormInstance *instances)
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
        // 塗りと輪郭は評価する位置が違う。**両方を持つ列では式を 1 回だけ解き**、輪郭の側は
        // 塗りの距離場を 1 次の近似でずらす (`mokume_shifted`。楕円の勾配は内外とも外向きなので
        // 使える)。輪郭しか持たない列では式を輪郭の位置で解く
        if (kFormHasFill) {
            fill = mokume_ellipseField(p, form.size.xy);
            // 1 画素より細い楕円の塗りは、`rect` の細い塗りと同じ境目で、両縁を見る積で
            // 数える (`mokume_thinEllipseCoverage`)。**距離場は細くても解く** — 輪郭の側が
            // それを読む (下の `mokume_shifted`)
            if (kFormHasThinFill
                && any(2.0 * form.size.xy * (1.0 + 2.0 * kFormSnap) < unitsPerPixel)) {
                isThinFill = true;
                thinFillCoverage = mokume_thinEllipseCoverage(p, form.size.xy, unitsPerPixel);
            }
        }
        if (kFormHasStroke) {
            FormField ring = kFormHasFill
                ? mokume_shifted(fill, in.strokeShift) : mokume_ellipseField(q, form.size.xy);
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
        if (kFormHasFill && kind != kFormLine) {
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
            // 絵は 1 ビットも変わらない
            float overlap = max(
                0.0,
                min(paint.fillCoverage, outerCoverage) - min(paint.fillCoverage, innerCoverage));
            float strokeAlpha = form.stroke.a;
            float visible = paint.fillCoverage - overlap * strokeAlpha;
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
/// なるので、混ぜるのを固定機能のブレンドへ渡せる。
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
    FormPaint paint = mokume_formPaint(in, instances);
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
    return mokume_formLayered(mokume_formPaint(in, instances));
}

/// 基本図形の断片 (置き換える列)。**下地を読まないが、余白は捨てる。**
///
/// 置き換える混ぜ方は下地を見ないので読む必要は無い。ただし**書けば下地が消える**ので、
/// 形の外の余白は捨てなければならない (重ねる列との違いはここ 1 点)。
fragment float4 mokume_formFragmentReplace(
    FormFragmentIn in [[stage_in]],
    constant FormInstance *instances [[buffer(10)]])
{
    FormPaint paint = mokume_formPaint(in, instances);
    if (mokume_formIsBlank(paint)) {
        discard_fragment();
        return float4(0.0);
    }
    return mokume_formLayered(paint);
}
