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
    /// 塗りの頂点を、置き場所ごとの記述 (`ThinFillRecord`) から頂点段で広げるか (#2208)。0 は広げない。
    /// 1 と 2 なら、`strokeStart` より前の頂点の `position` は「片の番号と角の番号」で、頂点段が片の
    /// 角を組む。2 は貼る絵があり、読み取り位置を `thinFillUV` の箱から作る。
    uint thinFill;
    /// 広げた片の貼る絵の読み取り位置を作る箱 (xy が下限・zw が上限。置き場所の位置を足す前)。`thinFill` が 2 のときだけ読む。
    float4 thinFillUV;
};

/// 細い塗りの置き場所ごとの記述 (#2208)。並びは Swift 側の `Canvas.ThinFillRecord` と一致する。
///
/// 片は、描く画素の空間の 2 つの基底で表した帯の列で、`layout.x` から `layout.y` を `layout.z` 個に
/// 割った刻みで `layout.w` 個並ぶ。**片の角を出す式は Swift 側の `ThinFillRecord.pieces()` と同じ**
/// (足し算と掛け算の順も同じ。積和は `fma` で順を固定し、割り算は丸めを揃えるため `precise` で行う)。
struct ThinFillRecord {
    /// 描く画素から形自身の座標へ戻す 2x2 (列 2 本を並べる)。
    float4 inverse;
    /// 形の中心 (xy) と、刻みの向き (zw・描く画素)。
    float4 centerAxis;
    /// 帯の幅の向き (xy)・弦の中点の傾き (z)・帯の半幅 (w)。
    float4 acrossSlopeSide;
    /// 刻みの始まり・刻み全体の長さ・割る数・片の数。
    float4 layout;
    /// 被覆の種別 (x: 0 一定・1 細長い楕円・2 表) と、種別ごとの値。
    float4 coverageMode;
    /// 被覆の表 (種別 2 だけが読む)。
    float4 table0;
    float4 table1;
    float4 table2;
};

/// 細い塗りの置き場所 1 つが持つ記述の並び (#2208): `thinFills` の `first` から `count` 個。
/// 並びは Swift 側の `Canvas.ThinFillSpan` と一致する。
struct ThinFillSpan {
    uint first;
    uint count;
    /// 置き場所の位置 (形自身の座標の原点を置く点。CPU が畳まずに置くときは周の中心へ足す)。
    float2 anchor;
    /// 置き場所の変換の平行移動 (`Transform.placed` が最後に足すもの)。
    float2 translation;
};

/// 片の角 (刻みの位置 `along`・帯の幅の向きの位置 `offset`) を形自身の座標で返す。
static inline float2 mokume_thinFillCorner(
    ThinFillRecord record, float2 anchor, float along, float offset)
{
    // **足し算も含めて演算の順を固定する。** 積和は `fma` で、足し算と掛け算は縮約も再結合もさせない
    // (UnitShape.metal の冒頭と同じ理由)。Shapes は既定の fast-math で組むので、`fadd(fma(a, b, c * d), e)` を
    // `fma(a, b, fma(c, d, e))` へ畳みうる。CPU の `ThinFillRecord.corner(anchor:along:offset:)` と
    // 同じ順で、読み戻しの検査 (`ThinFillVertexStageTests`) が 1 ビットずつ突き合わせる
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    float2 axis = record.centerAxis.zw;
    float2 across = record.acrossSlopeSide.xy;
    float slope = record.acrossSlopeSide.z;
    // 積和の順は `fma` で固定する (UnitShape.metal の冒頭と同じ理由)。Shapes は既定の fast-math で
    // 組むので、`a * b + c` と書くとどの積を融合するかをコンパイラが決める。CPU の
    // `ThinFillRecord.pieces()` も同じ順の `addingProduct` で書き、検査が許容 0 で突き合わせる
    float shift = fma(slope, along, offset);
    float2 drawn = fma(across, float2(shift), axis * along);
    float2 moved = fma(record.inverse.zw, float2(drawn.y), record.inverse.xy * drawn.x);
    // 周の中心に置き場所の位置を足してから、片の角を足す (CPU が畳まずに置くときと同じ順)
    float2 center = record.centerAxis.xy + anchor;
    return center + moved;
}

/// 広げた片の貼る絵の読み取り位置。箱 `bounds` (xy が下限・zw が上限) は置き場所の位置を足す前の周の
/// 囲みで、位置を足して幅を引き直す — CPU が周を置き場所ぶんずらしてから `boxUV` で作るのと同じ順。
static inline float2 mokume_thinFillUV(float4 bounds, float2 anchor, float2 position) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    float2 lowest = bounds.xy + anchor;
    float2 extent = (bounds.zw + anchor) - lowest;
    float2 mapped = float2(
        extent.x > 0.0 ? precise::divide(position.x - lowest.x, extent.x) : 0.0,
        extent.y > 0.0 ? precise::divide(position.y - lowest.y, extent.y) : 0.0);
    return clamp(mapped, float2(0.0), float2(1.0));
}

/// 形自身の座標の点 `position` を、置き場所の線形 `linear` (列 2 本)・平行移動 `translation` で置く。
/// CPU の `Transform.placed` (行列の積 `fma(列 y, y, 列 x * x)` の後に平行移動を足す) と同じ順。
static inline float2 mokume_thinFillPlace(float4 linear, float2 translation, float2 position) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    return fma(linear.zw, float2(position.y), linear.xy * position.x) + translation;
}

vertex ShapeFragmentIn shapeVertexMain(
    uint index [[vertex_id]],
    uint instance [[instance_id]],
    constant ShapeVertex *vertices [[buffer(0)]],
    constant FlatFrame &frame [[buffer(1)]],
    constant FlatInstance *instances [[buffer(10)]],
    constant float *coverages [[buffer(12)]],
    constant ThinFillRecord *thinFills [[buffer(13)]],
    constant ThinFillSpan *thinFillSpans [[buffer(14)]])
{
    ShapeVertex vertex_in = vertices[index];
    FlatInstance placement = instances[instance];

    // **細い塗りの雛形の塗りの頂点は、片の番号と角の番号だけを持つ** (#2208)。置き場所ごとの記述から
    // 片の角を形自身の座標で組み、以降は畳んだ頂点と同じ経路を通る。使わない片と、置かない片
    // (被覆 0) は、角を 1 点に潰して面積 0 にする
    float2 formPosition = vertex_in.position;
    float2 formUV = vertex_in.uv;
    float thinCoverage = 1.0;
    float2 thinSpanTranslation = float2(0.0);
    bool expandsThin = frame.thinFill != 0 && index < frame.strokeStart;
    if (expandsThin) {
        // 置き場所の記述は、先頭から順に片の数を引いて、片が入る記述を探す (塗りの置き場所は記述が 1 つ)
        ThinFillSpan recordSpan = thinFillSpans[instance];
        thinSpanTranslation = recordSpan.translation;
        uint slot = recordSpan.first;
        uint lastSlot = recordSpan.first + max(recordSpan.count, 1u) - 1u;
        float piece = vertex_in.position.x;
        while (slot < lastSlot && piece >= thinFills[slot].layout.w) {
            piece -= thinFills[slot].layout.w;
            slot += 1u;
        }
        ThinFillRecord record = thinFills[slot];
        uint corner = uint(vertex_in.position.y);
        float origin = record.layout.x;
        float side = record.acrossSlopeSide.w;
        // 使わない片 (雛形の区間が記述の片の数より大きいぶん) は、割り算も平方根も通さずに潰す
        bool alive = piece < record.layout.w;
        float along = origin;
        float offset = -side;
        float cover = 1.0;
        if (alive) {
            float span = record.layout.y;
            float divisor = record.layout.z;
            float from = origin + precise::divide(span * piece, divisor);
            float to = origin + precise::divide(span * (piece + 1.0), divisor);
            uint mode = uint(record.coverageMode.x);
            cover = record.coverageMode.y;
            if (mode == 1) {
                float thin = record.coverageMode.y;
                float longRadius = record.coverageMode.z;
                float width = record.coverageMode.w;
                float nearest = (from <= 0.0 && to >= 0.0) ? 0.0 : min(abs(from), abs(to));
                float ratio = min(precise::divide(nearest, longRadius), 1.0);
                float chord = thin * precise::sqrt(max(0.0, fma(-ratio, ratio, 1.0)));
                cover = chord > 0.0 ? precise::divide(chord, width) : 0.0;
            } else if (mode == 2) {
                uint entry = uint(piece);
                float4 row = entry < 4 ? record.table0 : (entry < 8 ? record.table1 : record.table2);
                cover = row[entry & 3u];
            }
            // 被覆 0 の片も置かない (種別 0 は一定の被覆で、0 でも置く)
            alive = mode == 0 || cover > 0.0;
            if (alive) {
                along = (corner == 1 || corner == 2) ? to : from;
                offset = corner < 2 ? -side : side;
                thinCoverage = cover;
            }
        }
        formPosition = mokume_thinFillCorner(record, recordSpan.anchor, along, offset);
        if (frame.thinFill == 2) {
            formUV = mokume_thinFillUV(frame.thinFillUV, recordSpan.anchor, formPosition);
        }
    }

    // **形自身の座標を、置き場所の変換で描画先の座標へ移す。** 何も動かさない置き場所
    // (単位行列) を通しても値は 1 ビットも変わらないので、畳めない頂点も同じ経路を通る
    float2 placed = placement.linear.xy * formPosition.x
        + placement.linear.zw * formPosition.y + placement.offset.xy;
    if (expandsThin) {
        // 広げた片は、畳まずに CPU が置いた頂点と 1 ビットも違わない位置に置く。畳まない細い塗りと同じ
        // フレームに並ぶので、順を固定しないと融合の仕方で位置が 1 つ違い、貼る絵の読み取りの継ぎ目や
        // 縁の画素が振れる。置き場所の位置は角へ足し済みで、平行移動は記述の並びが持つ
        placed = mokume_thinFillPlace(placement.linear, thinSpanTranslation, formPosition);
    }
    // **畳んだ雛形の輪郭は、置いた後・投影の前に半画素寄せる。** 塗りは整数の座標で
    // 画素の境目、線は画素の中心に乗る約束で (ADR-0039 決定 2)、置き場所ごとに回転や
    // 拡大が違っても画面でちょうど半画素になるよう、変換の後で足す。畳めない列は番号が
    // 最大なので足さない — そちらは CPU が描画先の座標で足し終えている (`Canvas+Outline`)
    if (index >= frame.strokeStart) {
        placed += 0.5;
    }

    ShapeFragmentIn out;
    out.position = frame.projection * float4(placed, 0.0, 1.0);
    out.uv = formUV;
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
    out.coverage = expandsThin ? thinCoverage : (frame.readsCoverage != 0 ? coverages[index] : 1.0);
    out.particleAge = 0.0;
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

/// 添字の最上位の桁。**立っていれば、桁を外した番号の頂点を読み、向きを裏返して出す**
/// ([#2222])。
///
/// 裏 → 表を 1 回で描く添字の列 (Swift 側の `SolidSweep.flipsNormal`) が、巻き方を入れ替えた
/// 写しの三角形のうち、形から求めた向きを持つ頂点にだけ立てる。写しは元が裏を向いているときだけ
/// 表を向いて残るので、断片は向きを裏返さない (`front_facing` が表)。そこで頂点の側で裏返し、
/// 元を置き場所ごとに描いたとき断片が裏返すのと同じ向きで光を当てる。**桁の立たない添字** (ほかの
/// 全部の描画・影の焼き付け・書かれた向きの写し) は、読む頂点も出す値も今までと変わらない。
///
/// [#2222]: https://github.com/mokume-metal/mokume/issues/2222
constant uint kSolidFlipsNormal = 0x80000000u;

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
    // 添字の最上位の桁は、向きを裏返す写しの印 (`kSolidFlipsNormal`)。読む番号は桁を外したもの
    bool flipsNormal = (index & kSolidFlipsNormal) != 0u;
    SolidVertex vertex_in = vertices[index & ~kSolidFlipsNormal];
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
    // 写しの向きは、移した後で符号だけを裏返す。断片が `-in.normal` で裏返すのと同じ値になる。
    // 形から求めたかの印 (`w`) はそのまま渡す
    out.normal = flipsNormal ? -out.normal : out.normal;
    out.isDerivedNormal = vertex_in.normal.w;
    // **利用者の断片へは、移す前の値をそのまま渡す。** 置き場所を通していないので
    // 形を動かしても回しても変わらず、ここから作った模様は形の表面に留まる (#367)
    out.shapePosition = vertex_in.shapePosition;
    out.shapeNormal = flipsNormal ? -vertex_in.shapeNormal : vertex_in.shapeNormal;
    out.coverage = isStroke ? vertex_in.stroke : 1.0;
    // 粒の置き場所だけが、面の向きの 1 列目の `w` に年齢を置く (Swift 側の `SolidInstance` を参照)。
    // 単位の形の寸法を `w` に持つ置き場所は、別の頂点関数 (`unitShapeVertexMain`) を通るので、
    // ここへ届くほかの置き場所の `w` は 0 である
    out.particleAge = placement.normal0.w;
    return out;
}

// 骨は形ごとに共用し、帯と角を置き場所・視点から頂点段で広げる (#1738)。
// 片の意味は `SolidStrokeGeometry.Piece` が持つ (a.w: 0 帯・2 網の点の半分・3 端の円板の 8 分の 1)。
struct SolidStrokePiece {
    float4 a;
    float4 b;
    float4 c;
};
// `forward.w` は画面の横 1 画素 ÷ 縦 1 画素の世界での長さ (縦横比を面と違えた投影で 1 でなくなる・#2176)、
// `down.w` はその逆数。`right.w` は端の形の番号 (`SolidStrokePlacement.capCode`)。
struct SolidStrokePlacement {
    float4x4 matrix;
    float4 eye;
    float4 right;
    float4 down;
    float4 forward;
    float4 parameters;
    float4 color;
    float4 uv;
    /// xyz: 単位の形の骨を元の寸法へ戻す軸ごとの倍率 (Swift 側の `SolidStrokePlacement` を参照)
    float4 shapeScale;
};

/// その位置での、画面の縦 1 画素ぶんの世界での長さ。横は `forward.w` 倍 (CPU の `StrokeCamera.worldPerPixel`)。
float solidStrokePixel(float3 p, constant SolidStrokePlacement &s) {
    if (s.eye.w != 0) {
        float depth = max(dot(p - s.eye.xyz, s.forward.xyz), s.parameters.z);
        return s.parameters.y * depth / s.parameters.w;
    }
    return s.parameters.y / s.parameters.w;
}

/// 見ている側へ寄せる量の 1 画素ぶんの長さ。画面の横と縦の長いほうで測る (CPU の `StrokeCamera.liftPerPixel`)。
float solidStrokeLiftPixel(float3 p, constant SolidStrokePlacement &s) {
    float vertical = solidStrokePixel(p, s);
    return s.forward.w > 1 ? vertical * s.forward.w : vertical;
}

/// 画面の画素で測った成分 (横, 縦) の向きを、世界の向きにする。CPU の `StrokeCamera.world(_:)` と同じ式。
float3 solidStrokeWorld(float2 screen, constant SolidStrokePlacement &s) {
    return (s.right.xyz * s.forward.w) * screen.x + s.down.xyz * screen.y;
}

/// 視線に直交する面の中の世界の向きを、画面の画素で測った成分 (横, 縦) にする。CPU の
/// `StrokeCamera.onScreen(_:)` と同じ式 (割り算は逆数の掛け算で持つ)。
float2 solidStrokeOnScreen(float3 v, constant SolidStrokePlacement &s) {
    return float2(dot(v, s.right.xyz) * s.down.w, dot(v, s.down.xyz));
}

/// 向きの決定 (同じ向きか・どちら回りか・潰れているか) に使う内積と外積。**CPU の式と同じ順の、融合しない
/// 積と和で書く** (#3165)。組み込みの `dot` / `cross` は `#pragma METAL fp contract(off)` の下でも積和へ縮約
/// されうるので、決定に使う式は明示する。積和の順を固定する前例は `mokume_thinFillCorner` (`math_mode(safe)` と
/// `contract(off)` を併記する)。3 成分の `dot` は `(x + y) + z`、外積の各成分は `a.y * b.z - a.z * b.y`。
/// CPU の `StrokeCamera.screenNormal` も、同じ明示の式で書いてある (simd の `cross` は clang が縮約するので使わない)。
static inline float solidStrokeDot2(float2 a, float2 b) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    return a.x * b.x + a.y * b.y;
}

static inline float solidStrokeDot3(float3 a, float3 b) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    return (a.x * b.x + a.y * b.y) + a.z * b.z;
}

static inline float3 solidStrokeCross3(float3 a, float3 b) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    return float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

/// 線分 a–b を画面に写したときの垂線の、画面の画素で測った成分 (横, 縦・長さ 1) を `normal` に入れる。
/// CPU の `StrokeCamera.screenNormal` と同じ式。画面での長さが 0 の線 (と長さ 0 の線分) なら偽。
///
/// **演算の順と丸めを CPU に揃える (#3165)。** 腕の向きは「値が等しいか」で同じ向きかを決める
/// (`Canvas.screenCorner`) ので、理屈では同じ向きの 2 本 (透視で、目と同じ直線に載る 2 点から出る腕など)
/// は、CPU と同じく 1 ビットも違わずに求めねばならない。Shapes は既定の fast-math で組むので、積和の縮約
/// (`dot` / `cross` を明示の積と和で書く) と、`length` / 割り算の近似 (`precise::` で正しく丸める) が、
/// 理屈では等しい 2 本の向きを 1 ビット違えて、同じ向きへ折り返す角の形を食い違わせていた。
bool solidStrokeNormal(float3 a, float3 b, constant SolidStrokePlacement &s, thread float2 &normal) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    float3 along = b - a;
    float2 raw;
    if (s.eye.w != 0) {
        float3 plane = solidStrokeCross3(a - s.eye.xyz, b - s.eye.xyz);
        raw = float2(solidStrokeDot3(plane, s.right.xyz) * s.forward.w, solidStrokeDot3(plane, s.down.xyz));
    } else {
        raw = float2(-solidStrokeDot3(along, s.down.xyz) * s.forward.w, solidStrokeDot3(along, s.right.xyz));
    }
    float size = precise::sqrt(raw.x * raw.x + raw.y * raw.y);
    if (!(solidStrokeDot3(along, along) > 0 && size > 0 && isfinite(size))) return false;
    normal = float2(precise::divide(raw.x, size), precise::divide(raw.y, size));
    return true;
}

/// 線分 a–b を画面に写したときの垂線を、世界の向き (画面の画素で長さ 1 の向きを世界へ直したもの) で
/// `side` に入れる。CPU の `Canvas.screenAcross` と同じ式。画面での長さが 0 の線 (と長さ 0 の線分) なら偽。
bool solidStrokeAcross(float3 a, float3 b, constant SolidStrokePlacement &s, thread float3 &side) {
    float2 normal;
    if (!solidStrokeNormal(a, b, s, normal)) return false;
    side = solidStrokeWorld(normal, s);
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

/// 軸ごとに倍率を掛けた形自身の座標を、置き場所の行列で世界の座標へ移す。**CPU の `matrix * SIMD4(point, 1)`
/// と同じ積和の順を `fma` で固定する** (#3165): 列 0 の積から始め、列 1・列 2 を `fma` で足し、最後に列 3 を
/// 足す (CPU の `simd` の行列とベクトルの積が、そう縮約されることを `swiftc -O` のアセンブリで確かめた)。
/// 位置が 1 ulp ずれると、同じ位置の点か (`samePoint`)・画面で潰れた辺か・同じ向きの腕かの判定が分かれる。
float3 solidStrokeMatrixPoint(float3 scaled, constant SolidStrokePlacement &s) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    float4 sum = s.matrix[0] * scaled.x;
    sum = fma(s.matrix[1], float4(scaled.y), sum);
    sum = fma(s.matrix[2], float4(scaled.z), sum);
    return (sum + s.matrix[3]).xyz;
}

/// 骨の点の位置 (形自身の座標) を、置いた後の世界の座標へ移す。
float3 solidStrokePlaced(float3 shape, constant SolidStrokePlacement &s) {
    return solidStrokeMatrixPoint(shape * s.shapeScale.xyz, s);
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

/// 2 本の向きの外積 (回る向きの判定)。CPU の `widestGap` の `cross` と同じ、融合しない積と差 (#3165)。
float solidStrokeCross(float2 a, float2 b) {
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)
    return a.x * b.y - a.y * b.x;
}

/// 骨の 2 点を結ぶ辺が画面で潰れているか。**辺の両端が同じ答えを得るよう、記録の位置が小さい点を
/// 先にして同じ式で判定する** — 引数の順を入れ替えると、積の丸めの向きが変わって外積が 0 に
/// なるかどうかが端ごとに食い違いうる (`solidStrokeNormal` は積と和を明示した式で、順を入れ替えれば値が変わる)
bool solidStrokeEdgeCollapsed(
    float3 p, uint recordP, float3 q, uint recordQ, constant SolidStrokePlacement &s)
{
    float2 normal;
    return recordP < recordQ ? !solidStrokeNormal(p, q, s, normal) : !solidStrokeNormal(q, p, s, normal);
}

/// 骨の点の奥行き (視点からの、視線に沿った距離)。CPU の `strokeNet` に渡す奥行きと同じ式
float solidStrokeDepth(float3 p, constant SolidStrokePlacement &s) {
    return solidStrokeDot3(p - s.eye.xyz, s.forward.xyz);
}

/// 網の点に置く形 (CPU の `Canvas.screenCorner` と同じ手順)。
struct SolidStrokeCorner {
    /// 0 何も置かない・1 円板・3 出っ張らせる端・4 折れ目。2 は欠番 (向きの無い点の、画面の軸に
    /// 沿った正方形だった。骨を作れる網では腕の無い群が現れず、届かないので消した・#2823)
    uint kind;
    float3 center;
    float3 origin1;
    float3 far1;
    float3 origin2;
    float3 far2;
};

// MARK: - 潰れた辺が何段も続く群 (同じ直線に載る辺の鎖・#2989)

/// 「slot が無い」の印。
constant uint kSolidStrokeNoSlot = 0xFFFFFFFFu;
/// 潰れた辺を何段までたどるか。同じ直線に載る辺の鎖は閉じない (閉じた形は 1 周で向きが変わる) ので
/// 届かない上限だが、骨の取り違えで終わらない繰り返しにならないよう置く
constant uint kSolidStrokeMaxRun = 1u << 16;

/// 点の記録が、隣の並びの後ろに対の相手の語を持つか (見出しの語の小数部が 0.5 のとき)。
bool solidStrokeHasPairs(uint record, constant float4 *words) {
    float count = words[record].w;
    return count != floor(count);
}

/// 点の記録 `record` (隣の数 `count`) の、隣 `slot` と同じ直線の向かい側に抜ける隣の slot。無ければ
/// `kSolidStrokeNoSlot`。**対を持つ記録 (`solidStrokeHasPairs`) にだけ呼ぶ。**
uint solidStrokePairSlot(uint record, uint count, uint slot, constant float4 *words) {
    float partner = words[record + 1 + count + slot / 4][slot % 4];
    return partner < 0 ? kSolidStrokeNoSlot : uint(partner);
}

/// 潰れた辺を 1 段たどる。点 `from` の隣 `slot` (潰れている辺) の先の点 `to`、`to` から `from` へ戻る辺の slot
/// (`back`)、`to` で同じ直線が向かい側へ続くときの slot (`onward`)。続くのは、対の相手の辺も潰れているとき。
void solidStrokeRunStep(
    uint from, uint slot, constant float4 *words, constant SolidStrokePlacement &s,
    thread uint &to, thread uint &back, thread uint &onward)
{
    to = uint(words[from + 1 + slot].w);
    uint count = uint(words[to].w);
    back = kSolidStrokeNoSlot;
    onward = kSolidStrokeNoSlot;
    for (uint k = 0; k < count; k++) {
        if (uint(words[to + 1 + k].w) == from) {
            back = k;
            break;
        }
    }
    if (back == kSolidStrokeNoSlot || !solidStrokeHasPairs(to, words)) return;
    uint partner = solidStrokePairSlot(to, count, back, words);
    if (partner == kSolidStrokeNoSlot) return;
    float4 entry = words[to + 1 + partner];
    if (solidStrokeEdgeCollapsed(
            solidStrokePlaced(words[to].xyz, s), to, solidStrokePlaced(entry.xyz, s), uint(entry.w), s))
    {
        onward = partner;
    }
}

/// 群の腕 1 本。
struct SolidStrokeArm {
    /// 群の中での番号 (手前の点の腕から、`slotA` の側へ、続けて `slotB` の側へ)
    uint index;
    /// 腕が出る点の記録 (同じ点から出た腕かを見分ける)
    uint origin;
    float3 originPoint;
    float3 farPoint;
};

/// 群の腕を順に返す。**手前の点の腕、`slotA` の側の点を手前から遠ざかる順、`slotB` の側の点を同じ順**に、
/// 点ごとに辺の順で、潰れた辺 (群の中の辺) を除いて並べる。
struct SolidStrokeRunCursor {
    uint center;
    uint slotA;
    uint slotB;
    /// いま腕を数えている点の記録と隣の数
    uint member;
    uint count;
    /// いまの点で腕に数えない隣 (群の中の辺)
    uint skipFirst;
    uint skipSecond;
    /// いまの点から次の点へ出る隣
    uint leave;
    /// 0 手前の点・1 `slotA` の側・2 `slotB` の側・3 終わり
    uint side;
    uint slot;
    uint steps;
    uint index;
};

SolidStrokeRunCursor solidStrokeRunStart(uint center, uint slotA, uint slotB, constant float4 *words) {
    SolidStrokeRunCursor c;
    c.center = center;
    c.slotA = slotA;
    c.slotB = slotB;
    c.member = center;
    c.count = uint(words[center].w);
    c.skipFirst = slotA;
    c.skipSecond = slotB;
    c.leave = kSolidStrokeNoSlot;
    c.side = 0;
    c.slot = 0;
    c.steps = 0;
    c.index = 0;
    return c;
}

/// 次の腕を `arm` に入れる。もう無ければ偽。
bool solidStrokeRunNext(
    thread SolidStrokeRunCursor &c, constant float4 *words, constant SolidStrokePlacement &s,
    thread SolidStrokeArm &arm)
{
    while (true) {
        while (c.slot < c.count) {
            uint k = c.slot;
            c.slot++;
            if (k == c.skipFirst || k == c.skipSecond) continue;
            arm.index = c.index;
            c.index++;
            arm.origin = c.member;
            arm.originPoint = solidStrokePlaced(words[c.member].xyz, s);
            arm.farPoint = solidStrokePlaced(words[c.member + 1 + k].xyz, s);
            return true;
        }
        // この点の腕は尽きた。同じ側の次の点へ進む。側が尽きたら次の側の最初の点へ
        while (true) {
            if (c.leave != kSolidStrokeNoSlot && c.steps < kSolidStrokeMaxRun) {
                c.steps++;
                uint to;
                uint back;
                uint onward;
                solidStrokeRunStep(c.member, c.leave, words, s, to, back, onward);
                c.member = to;
                c.count = uint(words[to].w);
                c.skipFirst = back;
                c.skipSecond = onward;
                c.leave = onward;
                c.slot = 0;
                break;
            }
            c.side++;
            if (c.side >= 3) return false;
            c.member = c.center;
            c.count = uint(words[c.center].w);
            c.slot = c.count;
            c.leave = c.side == 1 ? c.slotA : c.slotB;
            c.steps = 0;
        }
    }
}

/// 向き `toward` の腕のうち、群でいちばん先に現れる腕が出る点の記録。**同じ向きの腕は、最初に現れた点の
/// 腕だけを数える** (CPU の `screenCorner`: 別の点から出た同じ向きの腕は 1 本と数え、前の腕を残す。
/// 数える腕は「同じ向きの腕のうち、最初に現れた点から出たもの」になる)。
uint solidStrokeRunFirstOrigin(
    SolidStrokeRunCursor start, float2 toward, constant float4 *words, constant SolidStrokePlacement &s,
    uint fallback)
{
    SolidStrokeRunCursor c = start;
    SolidStrokeArm other;
    while (solidStrokeRunNext(c, words, s, other)) {
        float2 direction;
        if (solidStrokeToward(other.originPoint, other.farPoint, s, direction) && all(direction == toward)) {
            return other.origin;
        }
    }
    return fallback;
}

/// 群の腕 `arm` を数えるか。向きが無い (画面で潰れた) 腕と、同じ向きの先着の点でない腕は数えない。
bool solidStrokeRunKept(
    SolidStrokeRunCursor start, thread const SolidStrokeArm &arm, constant float4 *words,
    constant SolidStrokePlacement &s, thread float2 &toward)
{
    if (!solidStrokeToward(arm.originPoint, arm.farPoint, s, toward)) return false;
    return solidStrokeRunFirstOrigin(start, toward, words, s, arm.origin) == arm.origin;
}

/// 画面で潰れた辺が何段も続く群 (同じ直線に載る辺の鎖) に置く形。**群の手前の点だけが置く。**
/// 腕の数え方と形の決め方は `solidStrokeCornerShape` の、群が 1 点か 2 点のときと同じである。
SolidStrokeCorner solidStrokeRunShape(
    uint record, bool roundEnd, uint slotA, uint slotB, constant float4 *words,
    constant SolidStrokePlacement &s)
{
    SolidStrokeCorner result;
    result.kind = 0;
    float3 center = solidStrokePlaced(words[record].xyz, s);
    result.center = center;
    // 手前の点 (奥行きが等しければ記録の位置が小さい点) を、群の両側をたどって探す。自分でなければ置かない
    float depth = solidStrokeDepth(center, s);
    for (uint side = 0; side < 2; side++) {
        uint cur = record;
        uint slot = side == 0 ? slotA : slotB;
        for (uint step = 0; slot != kSolidStrokeNoSlot && step < kSolidStrokeMaxRun; step++) {
            uint to;
            uint back;
            uint onward;
            solidStrokeRunStep(cur, slot, words, s, to, back, onward);
            float other = solidStrokeDepth(solidStrokePlaced(words[to].xyz, s), s);
            if (other < depth || (other == depth && to < record)) return result;
            cur = to;
            slot = onward;
        }
    }
    SolidStrokeRunCursor start = solidStrokeRunStart(record, slotA, slotB, words);
    // 数える腕の数と、前の 2 本
    uint arms = 0;
    uint kept = 0;
    uint firstKept = 0;
    uint secondKept = 0;
    float2 firstToward = float2(0);
    {
        SolidStrokeRunCursor c = start;
        SolidStrokeArm arm;
        while (solidStrokeRunNext(c, words, s, arm)) {
            arms++;
            float2 toward;
            if (!solidStrokeRunKept(start, arm, words, s, toward)) continue;
            if (kept == 0) {
                firstKept = arm.index;
                firstToward = toward;
            } else if (kept == 1) {
                secondKept = arm.index;
            }
            kept++;
        }
    }
    uint a = firstKept;
    uint b = secondKept;
    uint cap = uint(s.right.w);
    if (kept == 0) {
        return result;
    } else if (kept == 1) {
        if (cap == 1) return result;
        if (cap == 2) {
            result.kind = 3;
        } else if (roundEnd) {
            result.kind = 1;
            return result;
        } else {
            if (arms < 2) return result;
            result.kind = 4;
            a = 0;
            b = 1;
        }
    } else if (kept == 2) {
        result.kind = 4;
    } else {
        // 時計回りの端を前から探す (`solidStrokeCornerShape` の、群が小さいときと同じ手順)
        float2 first = firstToward;
        {
            SolidStrokeRunCursor c = start;
            SolidStrokeArm arm;
            while (solidStrokeRunNext(c, words, s, arm)) {
                if (arm.index <= firstKept) continue;
                float2 toward;
                if (!solidStrokeRunKept(start, arm, words, s, toward)) continue;
                if (any(toward != first) && solidStrokeCross(first, toward) < 0) {
                    a = arm.index;
                    first = toward;
                }
            }
        }
        // 残りがすべて、時計回りの端から反時計回りに 180° 未満 (か同じ向き) に収まるか
        {
            SolidStrokeRunCursor c = start;
            SolidStrokeArm arm;
            while (solidStrokeRunNext(c, words, s, arm)) {
                float2 toward;
                if (arm.index == a || !solidStrokeRunKept(start, arm, words, s, toward)) continue;
                float turn = solidStrokeCross(first, toward);
                if (!(all(toward == first) || turn > 0 || (turn == 0 && dot(first, toward) > 0))) return result;
            }
        }
        b = a;
        float2 last = first;
        {
            SolidStrokeRunCursor c = start;
            SolidStrokeArm arm;
            while (solidStrokeRunNext(c, words, s, arm)) {
                float2 toward;
                if (!solidStrokeRunKept(start, arm, words, s, toward)) continue;
                if (any(toward != last) && solidStrokeCross(last, toward) > 0) {
                    b = arm.index;
                    last = toward;
                }
            }
        }
        result.kind = 4;
    }
    SolidStrokeRunCursor c = start;
    SolidStrokeArm arm;
    while (solidStrokeRunNext(c, words, s, arm)) {
        if (arm.index == a) {
            result.origin1 = arm.originPoint;
            result.far1 = arm.farPoint;
        }
        if (arm.index == b) {
            result.origin2 = arm.originPoint;
            result.far2 = arm.farPoint;
        }
    }
    return result;
}


/// 点の記録 `record` の点に置く形を決める (#1889・#1893・#1903 の決定)。
///
/// 画面で潰れた辺で結ばれた点を群とし、群のいちばん手前の点 (奥行きが等しければ記録の
/// 位置が小さい点) だけが置く (CPU の `strokeNet` と同じ選び方)。**群が 1 点か 2 点のときは、ここの手順で
/// 置く。潰れた辺が 3 点以上続くとき (同じ直線に載る向かい側の 2 辺の鎖) は、対の相手をたどって群を
/// 引き、`solidStrokeRunShape` が同じ手順で置く** (#2989)。
/// 群に集まる腕の画面での向きの数で、0 なら何も置かない・1 なら端 (`strokeCap`)・
/// 2 なら 2 本の折れ目・3 以上なら角度の順で 180° を越える間を挟む 2 本の折れ目 (無ければ何も
/// 置かない)。**0 本の群 (CPU の `Canvas.screenCorner` の向きの無い点) は、骨を作れる網では現れない。**
/// 現れうるのは、次数 1 の点 (辺が相手の 1 本だけ) と、潰れの判定と向きの判定が食い違う配置だけで、
/// 前者は `SolidStrokeGeometry` が網ごと骨を作らず、後者は `solidStrokeEdgeCollapsed` が両端で
/// 同じ式に揃えてあるので作れない (#2823)。
/// `roundEnd` は端の円板を置く容量を持つか。持たない点では、端の円板の代わりに
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
    uint slotA = kSolidStrokeNoSlot;
    uint slotB = kSolidStrokeNoSlot;
    for (uint k = 0; k < countI; k++) {
        float4 entry = words[record + 1 + k];
        if (solidStrokeEdgeCollapsed(center, record, solidStrokePlaced(entry.xyz, s), uint(entry.w), s)) {
            if (partners == 0) {
                g.partnerAt = k;
                g.recordJ = uint(entry.w);
                slotA = k;
            } else if (partners == 1) {
                slotB = k;
            }
            partners++;
        }
    }
    // 潰れた辺が 3 本以上ある点は、骨を作る網には現れない (`SolidStrokeGeometry` は 1 本の辺を 2 つの対に
    // 入れない)。置かない
    if (partners > 2) return result;
    if (partners == 2) {
        // 潰れた 2 本は同じ直線に載る対でなければ、群は 1 本の鎖にならない。置かない
        if (!solidStrokeHasPairs(record, words) || solidStrokePairSlot(record, countI, slotA, words) != slotB) {
            return result;
        }
        return solidStrokeRunShape(record, roundEnd, slotA, slotB, words, s);
    }
    if (partners == 1) {
        // 先の点で同じ直線がさらに潰れて続くなら、群は 3 点以上の鎖になる
        uint to;
        uint back;
        uint onward;
        solidStrokeRunStep(record, slotA, words, s, to, back, onward);
        if (onward != kSolidStrokeNoSlot) {
            return solidStrokeRunShape(record, roundEnd, slotA, kSolidStrokeNoSlot, words, s);
        }
    }
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
        // 腕の無い群は何も置かない (骨を作れる網には現れない・#2823)
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
        // 外積を見ない (CPU の `widestGap` と同じ手順で、値が等しい 2 本は外積の丸めを経ずに同じ向きと決める)
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
    float3 shapeA = piece.a.xyz * s.shapeScale.xyz;
    float3 shapeB = piece.b.xyz * s.shapeScale.xyz;
    float3 a = solidStrokeMatrixPoint(shapeA, s);
    float3 world = a;
    float3 shape = shapeA;
    float halfWeight = s.parameters.x / 2;
    if (piece.a.w == 0) {
        float3 b = solidStrokeMatrixPoint(shapeB, s);
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
                : placed.center + solidStrokeWorld(unit, s) * radius;
        }
    } else {
        // 網の点の半分 (#1644・#1889・#1893)。形は点の記録から決める (`solidStrokeCornerShape`)
        bool firstHalf = piece.b.y == 0;
        SolidStrokeCorner placed = solidStrokeCornerShape(uint(piece.b.x), piece.b.z != 0, words, s);
        float3 center = placed.center;
        float radius = halfWeight * solidStrokePixel(center, s);
        world = center;
        if (placed.kind == 3 && firstHalf) {
            // 出っ張らせる端。CPU の `appendSolidSquare(at:awayFrom:shape:half:camera:)` と同じ 2 軸
            float3 right;
            if (solidStrokeAcross(placed.far1, center, s, right)) {
                float2 onScreen = solidStrokeOnScreen(right, s);
                float3 down = solidStrokeWorld(float2(-onScreen.y, onScreen.x), s);
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
                float2 sideOwn = solidStrokeOnScreen(acrossOwn, s);
                // 同じ向きへ折り返す角では、2 枚が外側の縁を左右へ分ける (`b.y`)。**向きが等しいかは値で見る**
                // (CPU の `joinRim` では、等しい向きの内積 `dot(外側の縁の法線, inward)` がちょうど 0 で、縁は
                // 裏返らない)。内積を縮約すると 0 にならず、符号が 2 本で食い違うと縁が同じ側に揃って折り返しの
                // 先の延びが消える。内積は融合しない明示の式 (`solidStrokeDot2`) で書いて CPU と同じ値にするが、
                // 等しい向きは内積を見ずに分けたままにする二重の守りを置く (#3165)
                bool foldsBack = all(armOwn == armOther);
                float2 outerOwn = firstHalf ? float2(-armOwn.y, armOwn.x) : float2(armOwn.y, -armOwn.x);
                if (!foldsBack && solidStrokeDot2(outerOwn, inward) > 0) outerOwn = -outerOwn;
                float2 outerOther = firstHalf ? float2(armOther.y, -armOther.x) : float2(-armOther.y, armOther.x);
                if (!foldsBack && solidStrokeDot2(outerOther, inward) > 0) outerOther = -outerOther;
                // 丸めで −1…1 を越えると、同じ向きへ折り返す角で平方根が数でなくなる
                float cosine = clamp(solidStrokeDot2(outerOwn, outerOther), -1.0f, 1.0f);
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
                    case 0: world = center + solidStrokeWorld(inner, s) * radius; break;
                    case 1: world = center + edge; break;
                    case 2: world = center + solidStrokeWorld(cut, s) * radius; break;
                    default: world = center + solidStrokeWorld(middle, s) * radius; break;
                }
            }
        }
    }
    float lift = (s.parameters.x + 1) * solidStrokeLiftPixel(world, s);
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
    out.particleAge = 0.0;
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
    /// xy: 半幅・半高 (楕円は半径。線は半分の長さと 0)。z: 線幅の半分 (輪郭が無ければ 0)。
    /// w: 矩形の角の半径 (半幅・半高の小さいほう以下。丸めない矩形と矩形以外は 0・#2757)
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

/// この列が、描く画素で 1 画素より細い塗りか、1 画素より細い (潰れた) 輪郭の帯の穴を含みうるか。
/// **列ごとに決まる** ([#1477]・[#2186])。
///
/// 1 画素より細い塗りの枝 (`mokume_formPaint` の `rect` と楕円の塗り) と、帯の細い穴の枝
/// (`mokume_thinHole`) も、上の 2 つと同じ理由で特化して外す。枝は細い塗りに 1 度も入らない
/// 絵でも費用になり、面を覆う矩形 200 枚 (塗りだけ・1920×1080) で GPU 時間が 28% 増えていた。
/// 境目の比べ方を軽くしても消えず、原稿から外すと戻った。帯の細い穴の枝も、入るかは図形ごとの
/// 判定 (`FormFragmentIn.thinHole`) で決まるのに、**枝が原稿に在るだけで** 直径 700 の円 200 個
/// (塗り + 輪郭・太さ 7) の GPU 時間が 1 割増えた (#2186)。旗の名前は細い塗りの旗として入った
/// ときのままである (CPU 側の `FormInstance.thinFillsFlag`)。
///
/// **細い線と点の枝も同じ旗に乗る** ([#2226])。回した細い線の被覆は画素の四角を切る計算 (多角形の
/// 切り取り・`mokume_boxCoverage`) を持ち、細い線を含まない列まで払うと、輪郭の多い絵の費用になる。
///
/// 決めるのは CPU で、置いた時点の変換と大きさから保守側に倒して判定する
/// (`FormInstance.mayHaveThinFill`・`mayHaveThinHole`)。立っていても、細くない形は枝の中の判定で
/// 今までどおりの式を通るので、絵は変わらない。**立てるべき列で立て損なうと、細い塗りや帯の細い
/// 穴が縁 1 本の式に戻って絵が変わる** — だから判定は迷ったら「含む」側にする。列は旗で切らない
/// (細い塗りと太い塗りが混ざった列は、含む側の組で描く)。
///
/// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
/// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
/// [#2226]: https://github.com/mokume-metal/mokume/issues/2226
constant bool kFormHasThinFill [[function_constant(2)]];

/// 列に、縁の被覆を面積で数える画素がありうる形を含むか ([#2991])。回した・剪断した `rect`・線 (辺が斜め)、
/// 軸に沿っていても曲線の縁を持つ楕円・扇、軸に沿う `rect` の曲がった部分 (角の半径が 0 より大きい角丸・輪郭の
/// `strokeJoin(.round)`・`.bevel`) がそうである。決めるのは CPU で、**縁の分類の表** (`Kinds.metal` の
/// `mokume_formEdgeClass`・`mokume_formCoverageMode`・CPU の `FormInstance.EdgeClass`) から、置いた時点の変換と形を
/// 保守側に倒して判定する (`FormInstance.mayHaveObliqueEdge`)。
///
/// **例外: `point()` は回転によらず常に線形の渡し** (旗を立てない)。**丸い端の線の端も、回転によらず線形**
/// (回した線は辺だけ面積で、旗は立つ)。曲線の縁を持つが、既定の線を含む列に旗が立つと、線の多い絵が面積の枝の
/// 費用を払う。回転で線形と面積が切り替わると、1e-4 rad 回しただけで画素の値が飛ぶので、軸に沿うかで切り替えない。
///
/// **偽の列は、縁の被覆の面積の枝 (`mokume_formCoverage`) を原稿から外す。** 面積の枝は、枝が原稿に
/// 在るだけで、面を覆う塗り 200 枚 (軸に沿う `rect`・1920×1080) の GPU 時間が 1 割以上増えた。軸に沿った
/// `rect`・線だけの列は、従来の式だけを通るので、費用も絵も変わらない。立てるべき列で立て損なうと、斜めの縁が
/// 線形の渡しに戻って濃さが置く位置で振れる — だから判定は迷ったら「含む」側にする。
///
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
constant bool kFormHasObliqueEdge [[function_constant(3)]];

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
    /// 楕円の輪郭の距離場をどう出すか。楕円のインスタンスごとに決まる (`mokume_canShiftRing`・
    /// `mokume_needsExactRing`)。0: 輪郭の位置で近似の距離場を解き直す・
    /// 1: 塗りの距離場から、距離場そのものの勾配でずらす (`mokume_shiftedBySlope`)・
    /// 2: 円なので塗りの距離場から法線でずらす (`mokume_shifted`)・
    /// 3: 輪郭の位置で**真の距離**を解く (`mokume_ellipseExactField`・#2742)
    uint ringFromFill [[flat]];
    /// 輪郭の帯の穴が、描く画素で 1 画素より細いか潰れているか (`mokume_thinHole`)。`rect`・楕円・扇の
    /// インスタンスごとに決まる。0: 縁 1 本の距離場で数える・1: 両縁を見る積 (扇は画素の中の標本) で数える・
    /// 2: 穴は細くないが中心の角が尖った扇で、尖りの先の画素だけ標本で数える (`mokume_sectorApex`)
    uint thinHole [[flat]];
    /// 細い枝の境目を測る、描く画素の幅 (`mokume_reachPerPixel`)。**縁の形で分ける**: `rect`・線 (法線が一定の
    /// 直線の縁) は画素の法線向きの幅 (行の絶対値の和)、円・楕円・扇・丸い点 (法線が回る曲線) は行ノルム。
    /// インスタンスごとの量なので頂点で 1 度だけ出す (断片で出すと、面を覆う塗りの GPU 時間が 3 割ほど
    /// 増えた・#2991)
    float2 reachPerPixel [[flat]];
    /// 縁の被覆の数え方 (`kCoverage*`・`mokume_formCoverageMode`)。縁の分類の表 (`Kinds.metal`) が決める。
    /// これもインスタンスごとの量なので頂点で 1 度だけ出す
    uint coverageMode [[flat]];
    /// 扇の始まりと終わりの角の向き。xy が `(cos 始まり, sin 始まり)`、zw が `(cos 終わり, sin 終わり)`。
    /// 扇のインスタンスごとに一定なので、頂点関数が 1 度だけ求めて渡す (`mokume_sectorDirections`・
    /// [#2384](https://github.com/mokume-metal/mokume/issues/2384))。断片で求めると、塗りと輪郭の
    /// 距離場と穴の標本 (最大 65 回) のたびに三角関数 4 回を画素ごとに解く。扇でない形では 0
    float4 sectorDirections [[flat]];
    /// 弧の両端を結ぶ弦の直線 (`mokume_chordLine`)。xy は弧の側を向く単位法線、z は原点からその法線で測った弦までの
    /// 距離 (弧の側が `dot(p, xy) ≥ z`)。扇の置き場所でない形では 0。弦で結んだ形の内外の判定に使う
    /// ([#2428](https://github.com/mokume-metal/mokume/issues/2428))
    float4 chordLine [[flat]];
    /// 弧の真ん中の角の向き `(cos, sin)` (媒介変数の角)。開いた弧の帯の端の切り口が、どちらの端の担当かを決める。
    /// 扇の置き場所でない形では 0
    float2 arcMid [[flat]];
    uint instance [[flat]];
};

/// 楕円の輪郭を塗りの距離場から 1 次の近似でずらして出すときに、許す被覆率の誤差の見積もり
/// (`mokume_canShiftRing`)。表示の 1 段 (1/255) の半分である。
///
/// **見積もりは 1 次の項までで、厳密な上限ではない。** CPU の float64 のモデルで置き方を
/// 約 15,000 組探すと、実測は見積もりの最大で 1.04〜1.06 倍だった (半径 153.8・太さの半分 1.12
/// の円を、回して一様に 0.21 倍・細かさ 0.25 で置くと、見積もり 0.00195 に対して実測 0.00206)。
/// 1/255 (0.0039) の半分を余裕に取ってあるので、見積もりが最大で 6% ほど甘くても 1/255 の
/// 内側に収まる。**縁の被覆は面積で数える (#2991) ので、縁の中央の傾き (距離 1 画素あたりの被覆の変化) が
/// 縁の向きで 1〜√2 倍になる** (傾きは `1 / hi`・`hi` は画面の勾配の長辺で、45° が最大の √2 倍)。上の
/// 実測 (線形の渡しの傾き 1 で測った) は最大 √2 倍に読み替え、その最悪の例で 0.00206 × √2 = 0.0029 は
/// 1/255 の約 0.75 倍 (上限は越えない)。実機の半精度は 1 ulp (≈ 0.0005) の差が両側に出るので、実測は
/// そのぶんだけさらに大きい
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

/// 楕円の輪郭の内縁・外縁の位置のずれを許す大きさ (描く画素に対する比・`mokume_needsExactRing`)。
/// ADR-0039 の上限 1% の半分である (見積もりの粗さと、半精度の揺れの余裕)。**縁の被覆は面積で数える
/// (#2991) ので、位置のずれが被覆のずれになる倍率 (縁の中央の傾き) は向きで 1〜√2 倍になり、45° の縁では
/// 位置のずれ 0.5% が被覆のずれ約 0.71% になる** — 上限 1% の約 71% (上限は越えない)。
constant float kFormExactTolerance = 1.0 / 200.0;

/// 楕円の輪郭の内縁・外縁を、近似の距離場 (`mokume_ellipseField`) ではなく**真の距離**
/// (`mokume_ellipseExactField`) で数えるか ([#2742])。
///
/// 近似の距離場は縁の上でだけ真の距離と一致し、縁から離れるとずれる。内縁・外縁は縁から太さの
/// 半分だけ離れた所なので、そこでのずれが帯の位置のずれになる。長軸の端 (曲率半径
/// `短半径² / 長半径`) の近くで最も大きく、太さの半分がそれを越えると、内縁は長軸に沿って実際の穴の
/// 端を大きく越えて伸び、外縁は先端の外へはみ出す (`ellipse(0, 0, 100, 6)`・太さ 4 は帯が長軸に沿って
/// 丸ごと抜けた)。
///
/// **ずれの見積もりは `0.35 · (長半径 − 短半径) · 太さの半分² / 短半径²` (形自身の座標)。** 縁から
/// `h` (太さの半分) だけ離れた平行曲線の上で、近似の距離場と目標 (±`h`) の差を、CPU の 64 bit の
/// 模型で測った。`ρ = 短半径² / 長半径` として `h / ρ` が 0.1〜1、短半径 / 長半径が 0.01〜0.5 の範囲で、
/// 内縁側の差は `h · 0.31 · (1 − 短半径 / 長半径) · h / ρ` 以下 (外縁側はそれより小さい)。
/// 見積もりの係数 0.35 はそれを 1 割ほど上回る。`h / ρ` が 1 を越えると係数は 0.37 (h/ρ = 2) から
/// 増えて見積もりを下回るが、そこまで来れば見積もりは許容を大きく越える。円は距離場が真の
/// 距離なので 0。
///
/// 見積もりが描く画素の `kFormExactTolerance` に収まる楕円は、今までどおり近似の距離場で解く
/// (絵は 1 ビットも変わらない)。画素の大きさは、縦横で違う拡大・剪断でも保守側になるよう
/// 「描く画素 → 形自身の座標」の小さいほうの特異値で測る (`mokume_canShiftRing` と同じ)。
/// **大きさが 0・壊れた変換は、割り算を避けて比べるので常に真の距離の側**に倒れる。
///
/// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
static inline bool mokume_needsExactRing(float2 radii, float halfWeight, float4 drawnRows) {
    float longRadius = max(radii.x, radii.y);
    float shortRadius = max(min(radii.x, radii.y), 1e-30);
    float error = 0.35 * halfWeight * halfWeight * (longRadius - shortRadius)
        / (shortRadius * shortRadius);
    float determinant = abs(drawnRows.x * drawnRows.w - drawnRows.y * drawnRows.z);
    float squares = dot(drawnRows, drawnRows);
    float largest = sqrt(
        0.5 * (squares + sqrt(max(squares * squares - 4.0 * determinant * determinant, 0.0))));
    // 小さいほうの特異値は |det| / 大きいほう。割らずに「見積もり · 大きいほう > 許容 · |det|」で比べる
    return error * largest > kFormExactTolerance * determinant;
}

/// 形の軸が、描く画素の軸に沿っているか (逆行列の各行が、片方の軸だけを向く)。
///
/// 回していない形・90° の倍数に回した形・縦横で違う倍率の形がそうである。**行の小さいほうの
/// 成分が、大きいほうの 1e-5 倍以下なら沿っているとみなす** — 90° の回転は `cos` の丸め (4e-8)
/// で 0 にならないので、ちょうど 0 とは比べられない。1e-5 の傾きは、長さ 424 画素の線の端で
/// 0.004 画素しか動かず、絵に見えない。
static inline bool mokume_rowsAlignToPixels(float4 rows) {
    float2 a = abs(rows.xy);
    float2 b = abs(rows.zw);
    return min(a.x, a.y) <= 1e-5 * max(a.x, a.y) && min(b.x, b.y) <= 1e-5 * max(b.x, b.y);
}

/// 描く画素 1 つの、細い枝の境目を測る幅 (形自身の座標・x の向きと y の向き)。**縁の形で測り方を分ける**
/// ([#2991])。分け方は `Kinds.metal` の縁の分類の表 (`mokume_formReachCurved`・CPU の
/// `FormInstance.EdgeClass`) が決め、`curved` はその行ノルムの割合 (0 から 1)。
///
/// - **法線が一定の直線の縁 (`rect`・線) は、画素の正方形を形自身の軸へ射影した幅** — 逆行列の各行の
///   絶対値の和 (`|行.x| + |行.y|`)。45° に回した形では行ノルムの √2 倍になる。帯の両縁が 1 つの
///   画素に入るのは、帯の幅 (法線の向き) が、画素の正方形を法線へ射影した幅より細いときで、行ノルム
///   だと 45° でその幅を √2 だけ短く見積もり、境目の外 (縁 1 本の式) に、まだ両縁が入る太さの帯が
///   残っていた
/// - **法線が回る曲線の縁 (円・楕円・扇・丸い点・角丸の `rect`) は、向きによらない行ノルム** (`length(行)`)。
///   曲線の縁では、法線が縁に沿って一周するので、画素を法線へ射影した幅は縁の場所ごとに 1〜√2 の間を動き、
///   1 つの向きの幅では決まらない。そこへ和を持ち込むと、円を回すだけで境目が直径 1 から √2 へ動き、
///   同じ円の光の量が回す角で変わる (直径 1〜1.41 の円が細い枝へ入る・光の量が −6.7%〜+5.4% 動いた)。
///   扇の帯の穴は、内接円の半径 (向きを持たない量) を画素 3 つ分と比べる約束なので、これも行ノルム
/// - **丸い端の線は、半分の長さが太さの半分の 1/4 までは点 (行ノルム) から線 (和) へつなぐ** (割合は 1 −
///   半分の長さ / (太さの半分の 1/4))。点と長さ 1e-3 の線の間で境目が跳ばない。辺が画素ほど長い線は和で測る
///
/// 形の軸が画素の軸に沿うとき (`mokume_rowsAlignToPixels`) は、行の片方の成分が 0 で、和は行ノルムと
/// 一致する。**そのときは従来どおり行ノルムを返す** — 丸めの 1e-7 でも境目をまたがず、絵は 1 ビットも
/// 動かない。
///
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
static inline float2 mokume_reachPerPixel(float4 rows, float curved) {
    float2 norm = float2(length(rows.xy), length(rows.zw));
    if (curved >= 1.0 || mokume_rowsAlignToPixels(rows)) { return norm; }
    float2 sum = float2(abs(rows.x) + abs(rows.y), abs(rows.z) + abs(rows.w));
    return curved <= 0.0 ? sum : mix(sum, norm, curved);
}

/// 輪郭の帯の穴 (内縁の内) が、描く画素で 1 画素より細いか潰れているか ([#2186])。
/// `hole` は穴の半幅・半径 (形自身の座標。潰れていれば 0 以下)。
///
/// **縁 1 本の距離場は、穴の向こう側の縁を見られない。** 帯の被覆は「外縁の被覆 − 内縁の被覆」
/// なので、内縁の被覆が実際の穴より大きく出ると、そのぶん帯が欠けて下地が透ける。線幅が形より
/// 太いと穴は「どこにも無い」はずだが、`rect` は負の半幅が縁の渡し (1 画素) の内に残って内縁の
/// 被覆が 0 にならず (`rect(-0.3, -10, 0.6, 20)`・太さ 1 で帯の中心の画素に 0.15 が残った)、
/// 楕円は近似の距離場 (`mokume_ellipseField`) が長軸の上で先端までの距離を返すので、内縁が
/// 長軸の近くの画素を丸ごと覆った (`ellipse(0, 0, 0.7, 20)`・太さ 2 で帯が丸ごと抜けた)。
/// 1 画素より細い穴も、縁 1 本では穴の面積より大きく数える (塗りの #1477・線の #1451 と同じ)。
///
/// そこで、そうした穴は両縁を見る積で数える。境目は細い塗り・細い線と同じ 256/258 画素で、
/// それより太い穴は縁 1 本の式のまま (絵は 1 ビットも変わらない)。判定はインスタンスごとの量
/// なので、頂点関数が 1 度だけ出して断片へ渡す (`FormFragmentIn.thinHole`)。
///
/// **楕円の近似の距離場の外れは、別の枝で直す** ([#2742])。太さの半分が長軸の端の曲率半径
/// (`短半径² / 長半径`) を越える細長い楕円は、近似の距離場が帯の内縁・外縁を大きくずらすので、
/// 輪郭を真の距離で解く (`mokume_needsExactRing`・`mokume_ellipseExactField`)。ここで数えるのは
/// 穴が潰れているか 1 画素より細いときだけで、それより太い穴は真の距離の縁 1 本で数える。
/// 境目 (穴の幅が 1 画素) の両側で同じ帯が出る (`noFill()` の `ellipse(0, 0, 100, 6)` は太さ 5.0 の
/// 前後で欠けない)。扇の帯の穴は画素の中の標本で数える (`mokume_sectorHoleCoverage`・[#2747])。
///
/// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
/// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
/// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
static inline bool mokume_thinHole(float2 hole, float2 reachPerPixel) {
    return any(2.0 * hole * (1.0 + 2.0 * kFormSnap) < reachPerPixel);
}

/// 楕円の輪郭の帯の穴 (縁から太さの半分より内の所) の、短い向きの半幅と長い向きの端までの長さ
/// (形自身の座標・`radii` と同じ並び)。短い向きが 0 以下なら穴は無い ([#2186])。
///
/// - 短い向きは `短半径 − 太さの半分` で厳密 (短い軸の上の点から縁へのいちばん近い点は短い軸の
///   端)。楕円に内接するいちばん大きい円の半径は短半径なので、太さの半分がそれ以上なら穴は無い
/// - 長い向きの端は、太さの半分が長い軸の端の曲率半径 `短半径² / 長半径` までなら
///   `長半径 − 太さの半分`。越えると内縁は長い軸の端に届かない — 長い軸の上の点 x から縁までの
///   距離は `短半径 · √(1 − x² / (長半径² − 短半径²))` なので、それが太さの半分になる x で切れる。
///   2 つは曲率半径の所で連続につながる
///
/// 穴の形そのものは楕円ではない (内縁は楕円の平行曲線で、太いと端が尖る)。細い穴の被覆は
/// 半径だけでなく形に沿って数える (`mokume_thinEllipseHoleCoverage`)。
///
/// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
static inline float2 mokume_ellipseHole(float2 radii, float halfWeight) {
    float shortRadius = min(radii.x, radii.y);
    float longRadius = max(radii.x, radii.y);
    float shortHole = shortRadius - halfWeight;
    float ratio = halfWeight / max(shortRadius, 1e-30);
    float longHole = halfWeight * longRadius <= shortRadius * shortRadius
        ? longRadius - halfWeight
        : sqrt(max(longRadius * longRadius - shortRadius * shortRadius, 0.0))
            * sqrt(max(1.0 - ratio * ratio, 0.0));
    return radii.x <= radii.y ? float2(shortHole, longHole) : float2(longHole, shortHole);
}

/// 扇の中で、輪郭から最も深い所の深さ (扇に内接する円の半径) の上限 (形自身の座標・[#2747])。
/// 扇の帯の穴 (深さが太さの半分を越える所) の半径は、これから太さの半分を引いた値で抑えられる。
///
/// - **円の扇は厳密。** 掃引 θ が π 以下なら、2 本の半径と弧に接する円の半径
///   `半径 · sin(θ/2) / (1 + sin(θ/2))`。π 以上は中心から半径の半分の所に置いた円で、`半径 / 2`
///   (どちらも θ = π で半径 / 2 に一致する)
/// - **楕円の扇は上限。** 扇は短半径の円板に収まるので短半径以下で、媒介変数の空間 (半径で割った
///   空間) では単位円の扇なので、その内接円の半径を長半径倍した値でも抑えられる (内接円の像は
///   楕円で、その中に半径 / 長半径の円が入る)。小さいほうを返す
///
/// 上限なので、本当の穴より大きい穴の半径を返すことはあっても小さい穴の半径は返さない — 穴が
/// 潰れている (上限が太さの半分以下) と言えるときは確かに潰れている。
static inline float mokume_sectorDepthBound(float2 radii, float sweep) {
    float longRadius = max(radii.x, radii.y);
    float shortRadius = min(radii.x, radii.y);
    float halfSine = sin(0.5 * min(sweep, M_PI_F));
    return min(shortRadius, longRadius * halfSine / (1.0 + halfSine));
}

/// 扇の中で、輪郭から最も深い所の深さの**下限** (形自身の座標・[#2747])。上の上限と対で、真の深さは
/// 2 つの間にある。円の扇は上限と一致する。楕円の扇は、媒介変数の空間の単位円の扇の内接円 (半径
/// `半径比`) の像が楕円で、その中に半径 `短半径 · 半径比` の円が入るので、`短半径 · sin(θ/2) / (1 + sin(θ/2))`
/// (`arc(0, 0, 100, 60, 0, π)` で 15・上限は 25・実際は 15 ほど)。
///
/// **穴が細いかは、上限ではなく下限から測る。** 上限だけだと、楕円の扇は上限が実際の 1.7〜2 倍に緩く、
/// 本当は細い穴を太いと外す (太さ 30.1 で帯が最悪 45% 欠けた)。下限から測れば、細いかもしれない扇は
/// 標本の枝に入る (標本は真の距離で数えるので、細くなくても絵は縁 1 本と同じに近い)。
static inline float mokume_sectorDepthLower(float2 radii, float sweep) {
    float halfSine = sin(0.5 * min(sweep, M_PI_F));
    return min(radii.x, radii.y) * halfSine / (1.0 + halfSine);
}

/// 扇の穴の半径が、描く画素のいくつ分より小さければ「細い」として標本で数えるか。穴の端は尖り (内縁を
/// 作る縁が鋭い角で交わる)、縁 1 本の距離場は尖りの先で穴の向こう側の縁を見られない。半円の穴の半径で
/// 測ると、穴の半径 1.0 の欠けは 12.5%・2.5 は 7% で、1.5・2・3・4 は出なかった (4 通りの置き方)。
constant float kFormSectorHoleReach = 3.0;

/// 扇の始まりと終わりの角の向き (`float4`): xy が `(cos 始まり, sin 始まり)`、zw が
/// `(cos 終わり, sin 終わり)` ([#2384](https://github.com/mokume-metal/mokume/issues/2384))。
/// 終わりの角は `始まり + 掃引` を 1 度足してから求める (距離場が以前に断片で求めていた式のまま)。
/// **インスタンスごとに一定の値なので、頂点関数が 1 度だけ求めて `[[flat]]` で渡し、距離場は
/// 画素ごとに三角関数を解かない。**
static inline float4 mokume_sectorDirections(float start, float sweep) {
    float end = start + sweep;
    return float4(cos(start), sin(start), cos(end), sin(end));
}

/// 扇の中心の角が作る穴の尖り (`float4`): xy は尖りの位置 (形自身の座標)、z は角の半分の正弦、w は
/// 尖った角か (掃引が π 未満で、角の半分の正弦が 0.5 未満・角が 60° 未満)。
///
/// 中心の角 (掃引 θ) は、内側へ太さの半分だけ縮めても同じ角度の尖りになる。縁 1 本の距離場は、尖りの
/// 先の画素で距離が小さいまま長く残り、尖りから離れた画素まで被覆が残る — 尖りまでの距離 t のとき被覆の
/// 余りは `0.5 − t · sin(θ/2)` で、θ が小さいほど遠くまで残る (`arc(0, 0, 400, 400, …, 0.1)`・太さ 10 で、
/// 穴は太い (半径 4.5) のに尖りの先の画素が 52% 欠けた)。角は 2 本の半径の向きで決まる (楕円の扇は
/// 媒介変数の角ではなく、弧の端の位置ベクトルの向き)。
static inline float4 mokume_sectorApex(
    float2 radii, float4 directions, float sweep, float halfWeight)
{
    float2 direction1 = normalize(radii * directions.xy);
    float2 direction2 = normalize(radii * directions.zw);
    float2 bisector = normalize(direction1 + direction2);
    float sineHalf = abs(direction1.x * bisector.y - direction1.y * bisector.x);
    float2 tip = bisector * (halfWeight / max(sineHalf, 1e-6));
    return float4(tip, sineHalf, (sweep < M_PI_F && sineHalf < 0.5) ? 1.0 : 0.0);
}

/// 扇の置き場所の閉じ方 (`kArc*`・[#2428](https://github.com/mokume-metal/mokume/issues/2428))。置き場所の
/// `size.w` が持つ (矩形の角の半径の欄で、扇では未使用だった)。扇でない形は `kArcPie` (読まない)。
/// **列を切る旗 (`meta.w`) には入れない** — 閉じ方違いも、寸法違いや種別違いと同じ 1 列に並ぶ。
static inline uint mokume_arcClosure(FormInstance form) {
    return form.meta.x == kFormArc ? uint(form.size.w) : kArcPie;
}

/// 塗りが「弧の両端を弦で結んだ形」か (そうでなければ扇)。
static inline bool mokume_arcFillsChord(uint closure) {
    return closure == kArcChord || closure == kArcOpen;
}

/// 輪郭が「閉じない弧の帯」か (そうでなければ、扇か弦で結んだ形の周の帯)。
static inline bool mokume_arcStrokesOpen(uint closure) {
    return closure == kArcStandard || closure == kArcOpen;
}

/// 弧の両端を結ぶ弦の直線 (`float4`): xy は弧の側を向く単位法線、z は原点からその法線で測った弦までの距離
/// (弧の側が `dot(p, xy) ≥ z`)。w は未使用。
///
/// 媒介変数の空間 (半径で割った空間) では、弧は単位円の弧で、弦は真ん中の角 `tm = start + sweep / 2` の向きに
/// 距離 `cos(sweep / 2)` の直線 (弧の側が `u · (cos tm, sin tm) ≥ cos(sweep / 2)`) である。実際の座標へ戻すと、
/// 法線は `(cos tm / rx, sin tm / ry)`。**掃引が π を越えても同じ式で、弧の側が広いほうになる。**
static inline float4 mokume_chordLine(float2 radii, float start, float sweep) {
    float middle = start + 0.5 * sweep;
    float2 normal = float2(cos(middle) / radii.x, sin(middle) / radii.y);
    float length2 = max(dot(normal, normal), 1e-30);
    float inverseLength = rsqrt(length2);
    return float4(normal * inverseLength, cos(0.5 * sweep) * inverseLength, 0.0);
}

/// 弦で結んだ形の中で、輪郭から最も深い所の深さの上限 (形自身の座標・`mokume_sectorDepthBound` と対)。
///
/// 媒介変数の空間では単位円の弓形で、そこへ内接する円は、弧の真ん中と弦の真ん中を結ぶ線分を直径に取る
/// 円 (半径 `(1 − cos(sweep / 2)) / 2`) が最大である — 掃引が π を越えても成り立つ (大きい弓形の高さは
/// 半径を越え、内接円は弧の反対側の端と弦に接する)。実際の座標へ戻すと、短半径の円板に収まる上限と、
/// 長半径倍した上限の小さいほう。
static inline float mokume_chordDepthBound(float2 radii, float sweep) {
    float ratio = 0.5 * (1.0 - cos(0.5 * sweep));
    return min(min(radii.x, radii.y), max(radii.x, radii.y) * ratio);
}

/// 弦で結んだ形の中で、輪郭から最も深い所の深さの下限 (`mokume_sectorDepthLower` と対)。内接円の像が楕円で、
/// その中に半径 `短半径 · 半径比` の円が入る。
static inline float mokume_chordDepthLower(float2 radii, float sweep) {
    return min(radii.x, radii.y) * 0.5 * (1.0 - cos(0.5 * sweep));
}

/// 弦で結んだ形の 2 つの角 (弧と弦が出会う弧の両端) が作る穴の尖り (`mokume_sectorApex` と対・`float4`):
/// xy は尖りの位置、z は角の半分の正弦、w は尖った角か (角が 60° 未満)。`corner` が 0 なら弧の始まりの端、
/// 1 なら終わりの端。角は「弧の接線 (弦から離れる向き) と弦」が作る角で、弓形が薄い (掃引が小さい) ほど鋭い。
/// 掃引が 2π に近く弦が点に潰れる角は、2 つの向きが逆向きになって二等分線が定まらないので尖りなしとする。
static inline float4 mokume_chordApex(float2 radii, float4 directions, float halfWeight, uint corner) {
    float2 end1 = radii * directions.xy;
    float2 end2 = radii * directions.zw;
    float2 end = corner == 0u ? end1 : end2;
    float2 other = corner == 0u ? end2 : end1;
    float2 tangent = corner == 0u
        ? radii * float2(-directions.y, directions.x)
        : -(radii * float2(-directions.w, directions.z));
    float2 along = tangent * rsqrt(max(dot(tangent, tangent), 1e-30));
    float2 chord = other - end;
    float2 across = chord * rsqrt(max(dot(chord, chord), 1e-30));
    float2 sum = along + across;
    float sumLength = length(sum);
    if (sumLength < 1e-4) { return float4(0.0, 0.0, 1.0, 0.0); }
    float2 bisector = sum / sumLength;
    float sineHalf = abs(along.x * bisector.y - along.y * bisector.x);
    float2 tip = end + bisector * (halfWeight / max(sineHalf, 1e-6));
    return float4(tip, sineHalf, sineHalf < 0.5 ? 1.0 : 0.0);
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
    //
    // 開いた弧の帯で端の形が `project` なら、端から接線の向きに半分の太さだけ出る長方形が、楕円の箱の外へ
    // `halfWeight · √2` まで出うる (`mokume_arcBandField`)。余裕を持って 1.5 倍を取る
    uint arcClosure = mokume_arcClosure(form);
    bool projectsArcCaps = form.meta.x == kFormArc && mokume_arcStrokesOpen(arcClosure)
        && form.meta.y == kFormCapProject;
    float2 extent = form.meta.x == kFormLine
        ? float2(form.size.x + halfWeight, halfWeight)
        : form.size.xy + (projectsArcCaps ? 1.5 * halfWeight : halfWeight);

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
    // **縁の分類は 1 か所の表** (`Kinds.metal` の `mokume_formEdgeClass`・CPU の `FormInstance.EdgeClass`)。
    // 境目の幅も被覆の数え方も、それを読む
    uint edgeClass = mokume_formEdgeClass(
        form.meta.x, form.size.x, form.size.w, (form.meta.w & kFormStrokes) != 0, form.meta.y, form.meta.z);
    out.reachPerPixel = mokume_reachPerPixel(drawnRows, mokume_formReachCurved(edgeClass, form.size.x, halfWeight));
    out.coverageMode = mokume_formCoverageMode(edgeClass, mokume_rowsAlignToPixels(drawnRows));
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
    // 近似の距離場が内縁・外縁をずらしすぎる楕円は、真の距離で解く (3・#2742)。ずらす近似
    // (1・2) は近似の距離場そのものを足し引きするので、そもそも使えない
    out.ringFromFill = 0u;
    if (form.meta.x == kFormEllipse) {
        if (mokume_needsExactRing(form.size.xy, halfWeight, drawnRows)) {
            out.ringFromFill = 3u;
        } else if (mokume_canShiftRing(form.size.xy, halfWeight, out.strokeShift, drawnRows)) {
            out.ringFromFill = form.size.x == form.size.y ? 2u : 1u;
        }
    } else if (form.meta.x == kFormArc && mokume_needsExactRing(form.size.xy, halfWeight, drawnRows)) {
        // 扇も、扇が持つ楕円の弧の距離場が同じ外れ方をする (#2747)。ずらす近似は使わない扇なので、
        // 0 か 3 のどちらか
        out.ringFromFill = 3u;
    }
    // 輪郭の帯の穴が 1 画素より細いか潰れているか。これもインスタンスごとの量なので頂点で 1 度だけ
    // 出す — 断片で出すと、楕円の穴の半径 (平方根 2 つ) を画素ごとに解き、面を覆う円で GPU 時間が
    // 2 割増えた (#2186)。穴を測る幅は、縁の形で分けた描く画素の幅 (`mokume_reachPerPixel`・直線の縁の穴は
    // 法線向きの幅、楕円と扇の穴と、内縁に丸い角が残る `rect` の穴は行ノルム。#2991)。断片の
    // `unitsPerPixel` (行ノルム) とは、直線の縁の形で違う
    float2 drawnUnits = mokume_reachPerPixel(
        drawnRows, mokume_formHoleCurved(edgeClass, form.size.w, halfWeight) ? 1.0 : 0.0);
    // 扇の穴は、内接円の半径の下限から太さの半分を引いた半径を、`kFormSectorHoleReach` 画素で測る
    // (半径が画素の 3 つ分より小さければ細い)。`mokume_thinHole` は半幅が画素の半分より小さいかを
    // 見るので、半径を 2 · `kFormSectorHoleReach` で割って渡す。弦で結んだ形の周は弓形の内接円で測る。
    // **開いた弧の帯 (`kArcStandard`・`kArcOpen`) は穴を持たない** (閉じた周が無い)
    bool arcHasHole = form.meta.x == kFormArc && !mokume_arcStrokesOpen(arcClosure);
    float arcDepthLower = arcClosure == kArcChord
        ? mokume_chordDepthLower(form.size.xy, form.offset.w)
        : mokume_sectorDepthLower(form.size.xy, form.offset.w);
    float2 hole = form.meta.x == kFormEllipse
        ? mokume_ellipseHole(form.size.xy, halfWeight)
        : (form.meta.x == kFormArc
            ? float2(arcDepthLower - halfWeight) / (2.0 * kFormSectorHoleReach)
            : form.size.xy - halfWeight);
    out.thinHole =
        ((form.meta.x == kFormRect || form.meta.x == kFormEllipse || arcHasHole)
            && mokume_thinHole(hole, drawnUnits))
        ? 1u : 0u;
    // 扇の始まりと終わりの角の向きは、インスタンスごとに一定。ここで 1 度だけ求めて断片へ渡す
    // (断片の距離場・穴の標本・尖りの判定は、画素ごとに三角関数を解かない・#2384)
    out.sectorDirections = form.meta.x == kFormArc
        ? mokume_sectorDirections(form.offset.z, form.offset.w)
        : float4(0.0);
    // 弦の直線と弧の真ん中の向きも同じ (弦で結んだ形と開いた弧の帯が読む・#2428)
    bool arcNeedsChord = form.meta.x == kFormArc
        && (mokume_arcFillsChord(arcClosure) || mokume_arcStrokesOpen(arcClosure));
    out.chordLine = arcNeedsChord ? mokume_chordLine(form.size.xy, form.offset.z, form.offset.w) : float4(0.0);
    out.arcMid = arcNeedsChord
        ? float2(cos(form.offset.z + 0.5 * form.offset.w), sin(form.offset.z + 0.5 * form.offset.w))
        : float2(0.0);
    // 穴が細くない扇でも、中心の角 (弦で結んだ形の周は弧の両端の 2 つの角) が尖っていれば、尖りの先の画素を
    // 標本で数える (2)
    if (out.thinHole == 0u && arcHasHole) {
        bool sharp = arcClosure == kArcChord
            ? (mokume_chordApex(form.size.xy, out.sectorDirections, halfWeight, 0u).w > 0.0
                || mokume_chordApex(form.size.xy, out.sectorDirections, halfWeight, 1u).w > 0.0)
            : mokume_sectorApex(form.size.xy, out.sectorDirections, form.offset.w, halfWeight).w > 0.0;
        if (sharp) { out.thinHole = 2u; }
    }
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

/// 画素の正方形 [−0.5, 0.5]² (`d`) の上で、`g · d ≤ t` になる面積 ([#2991])。`g` は、形の軸 (または縁の
/// 法線) の座標が描く画素の `d` でどう動くか (縁の勾配を画面へ写したもの・`hi` が長辺・`lo` が短辺)。
///
/// `g · d` は、幅 |g.x| と |g.y| の一様分布の和で、密度は台形になる。この関数はその累積分布 F の `t` での値で、
/// **縁 1 本の被覆 (`mokume_formCoverage`・半平面と画素の重なりの面積 = `F(−c)`) と、帯 1 本の被覆
/// (`mokume_stripCoverage` = `F(h − c) − F(−h − c)`) が同じ式を使う**。`s = (hi + lo) / 2`・
/// `k = (hi − lo) / 2` として、分布は 0 について対称なので、`u = |t|` の下側の裾 `G(u) = F(−u)` を取り
/// (`F(t) = t ≤ 0 ? G : 1 − G`)、`u ≥ s` は 0 / 1 (縁を含まない画素はここで済む)、`u ≥ k` なら
/// `(s − u)² / (2 · lo · hi)`、`u < k` なら `0.5 − u / hi`。
///
/// **4 項の 2 乗の和を引く書き方は、短辺が長辺の 1e-5 ほどになる (ほぼ軸に沿う) と桁が落ちる** — `hi²` の大きさの
/// 項の差を `lo · hi` で割るので、32 bit の丸めが `hi / lo` 倍に増え、画素ごとに 0.01 外れた。裾の形は
/// `s − u ≤ lo` の小さい値だけを 2 乗するので、割っても丸めは大きくならない。**短辺が長辺の 1e-5 以下
/// (ほぼ軸に沿う) ときは一様分布で、累積は 1 次式になる** (割ると桁が落ちるので、裾の式へ入れない)。
/// 早期の 0 / 1 を先に置くのは、縁を含まない画素 (面の大半) の費用のため (回した面を覆う塗り・直径 700 の
/// 円で、判定の順を入れ替えると GPU 時間が 2〜3% 動いた)。**値は、短辺が長辺の 1e-5 以下の (ほぼ軸に沿う)
/// 帯の枝で、`u ≥ s` のとき一様分布の式が返す 1 + lo / (2 · hi) (最大 5e-6 の超過) の代わりに 0 / 1 を返すだけ
/// 動く。** 片方の行だけほぼ軸に沿う剪断の細い帯の被覆が、8 bit の丸めの境目でしか変わらない (差は最大
/// `lo / hi` ≤ 1e-5)。
///
/// 画素の和が縁の長さ×法線の向きの厚みに一致するのは、画素の軸に沿った正方形で重なりを取るときである。
/// 線形の渡し (`0.5 − c / 長さ`) は、縁が画素の軸に沿うときだけこれと一致する。
///
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
static inline float mokume_pixelCdf(float t, float hi, float lo) {
    float s = 0.5 * (hi + lo);
    float u = abs(t);
    if (u >= s) { return t > 0.0 ? 1.0 : 0.0; }
    if (lo <= 1e-5 * hi) { return 0.5 + t / max(hi, 1e-30); }
    float k = 0.5 * (hi - lo);
    float ramp = s - u;
    float tail = u >= k ? ramp * ramp / (2.0 * lo * hi) : 0.5 - u / hi;
    return t <= 0.0 ? tail : 1.0 - tail;
}

/// 距離場から被覆率を出す。**縁を 1 画素の幅で線形に渡す** (箱フィルタと同じ)。
///
/// **縁の向きが画素の軸に斜めなら、渡しではなく半平面と画素の正方形の重なりの面積で数える**
/// (`mokume_pixelCdf`・[#2991])。画素の和が面積に一致するのは、そのときだけである。
/// `linear` は、この縁を線形の渡しのまま数えるか (縁の分類の表と被覆の数え方 `kCoverage*`・`mokume_formPaint`)。
/// 真なら縁の向きによらず従来の式のまま返す (角の外の斜めの距離を含む。絵は 1 ビットも動かない)。
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
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
/// [#3493]: https://github.com/mokume-metal/mokume/issues/3493
static inline float mokume_formCoverage(FormField field, float4 inverseRows, bool linear) {
    float2 n = field.gradient;
    float2 screen = float2(
        inverseRows.x * n.x + inverseRows.z * n.y,
        inverseRows.y * n.x + inverseRows.w * n.y);
    if (kFormHasObliqueEdge && !linear) {
        // **縁の向きが画素の軸に斜めなら、半平面と画素の正方形の重なりの面積で数える** ([#2991])。
        // 線形の渡しは、縁が画素の軸に沿うときだけ面積に一致する (45° の縁では、画素の中心が法線の向きに
        // 1/√2 おきに並ぶので、渡しの和が置く位置で振れる)。直線の縁だけの形の軸が画素の軸に沿うとき
        // (`linear`) は、従来の式のまま返す — 絵は 1 ビットも動かない。**曲線の縁と、軸に沿う
        // `rect` の曲がった部分 (角丸・丸い折れ目・削ぎ) は、軸に沿った形でも面積で数える**。斜めの縁を含みうる
        // 形を含まない列 (`kFormHasObliqueEdge` が偽) は、この枝ごと原稿から外す
        //
        // **「面積で数える」は、直線の縁では厳密で、曲線の縁では接線の半平面で数える近似である** ([#3493])。
        // 円板は凸なので接線の半平面に丸ごと含まれ、凸の縁 (円・楕円・扇の外縁・角丸の角) は面積より明るく、
        // 凹の縁 (輪郭の帯の内縁) は同じ大きさで暗く出る。差は描く画素での曲率半径 R に反比例して、約 k / R (k = 0.12。
        // 画素の中の接線の長さ L に対する弧との間の面積 `L³ / (24 R)` が、対角 L = √2 で最大)。R = 3 の実測は最大 0.037 (9/255 ほど) で、
        // R = 7 以上は 0.02 の内。この式は変えない — 曲率で補うと曲線の縁の全画素に費用が掛かる。楕円の R は場所ごとに変わり
        // (最小は 短半径² / 長半径)、楕円は距離場そのものが近似 (ADR-0039) なので別の誤差が重なる。測ったのは円だけ
        // (`CoverageTable.curvatureConstant`)
        //
        // 両端の遊び (下) は、面積にも同じく掛ける。面積の裾 (1/256 未満) を 0 に揃えないと、面積が 1e-4 ほど
        // しか掛からない画素に被覆が残り、置き換える混ぜ方 (`replace`) が下地を消す (実測)。裾だけを
        // 切ると、輪郭を塗りの距離場からずらす近似の経路 (勾配の向きが僅かに違う) と、輪郭の位置で解く
        // 経路で、切る所をまたいだ画素が 1/255 を越えて食い違う。全体を同じ式で写せば食い違いは連続になる
        float hi = max(abs(screen.x), abs(screen.y));
        float lo = min(abs(screen.x), abs(screen.y));
        return saturate(
            mokume_pixelCdf(-field.distance, hi, lo) * (1.0 + 2.0 * kFormSnap) - kFormSnap);
    }
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

/// 画素 [−0.5, 0.5]² の中で、`c + g · d` が `[−h, h]` に入る面積 (帯 1 本・閉じた式)。
/// `g` は、形のその軸の座標が描く画素の `d` でどう動くか (`inverseRows` の 1 行)。
///
/// 累積分布 `mokume_pixelCdf` (`g · d` の台形の分布) を、帯の両縁 (`h − c` と `−h − c`) で引く。縁 1 本の被覆
/// (`mokume_formCoverage`) と同じ式で、桁落ちを避ける書き方も `mokume_pixelCdf` にある。
static inline float mokume_stripCoverage(float c, float h, float2 g) {
    float hi = max(abs(g.x), abs(g.y));
    float lo = min(abs(g.x), abs(g.y));
    return mokume_pixelCdf(h - c, hi, lo) - mokume_pixelCdf(-h - c, hi, lo);
}

/// 凸多角形 `poly[0..<n]` を、`k + g · d ≥ 0` の側だけに切る (Sutherland–Hodgman)。
static inline void mokume_clipPolygon(thread float2 *poly, thread uint &n, float k, float2 g) {
    float2 kept[10];
    uint m = 0;
    for (uint i = 0; i < n; i++) {
        float2 current = poly[i];
        float2 next = poly[i + 1 == n ? 0 : i + 1];
        float fc = k + dot(g, current);
        float fn = k + dot(g, next);
        bool inside = fc >= 0.0;
        if (inside) { kept[m++] = current; }
        if (inside != (fn >= 0.0)) {
            kept[m++] = mix(current, next, fc / (fc - fn));
        }
    }
    for (uint i = 0; i < m; i++) { poly[i] = kept[i]; }
    n = m;
}

/// 形自身の軸に沿った箱 (中心 `at`・半幅 `extent`・どれも形自身の座標) と、**描く画素の軸に沿った
/// 正方形** (描く画素 1 つ) の重なりの面積 ([#2226])。1 画素より細い線・点・塗りの被覆が使う。
///
/// 形の向きの 2 軸で `mokume_spanCoverage` を取って掛ける式は、画素を形の向きに回した正方形で
/// 数えることになる。画素の格子は軸に沿った正方形が隙間なく並ぶので、数えた画素の和が形の面積に
/// 一致するのは、画素の軸に沿った正方形で重なりを取るときだけである — 45° の細い線では、置く位置
/// だけで光の量が 0.7〜1.4 倍に振れた。ここでは重なりの面積をそのまま出すので、画素の和は、
/// 向きにも置く位置にも、剪断と縦横で違う倍率にもよらず、箱の面積に一致する。
///
/// - **形の軸が画素の軸に沿うとき** (`mokume_rowsAlignToPixels`) は、軸ごとの重なりの長さの積が
///   厳密なので、従来と同じ演算でそれを返す。軸に沿った形の絵は 1 ビットも動かない
/// - 画素が箱の片側の帯に丸ごと入るか、帯が画素を切らないなら、帯 1 本の閉じた式で出す
///   (`mokume_stripCoverage`)。長い線の中ほどはこれで済み、頂点を切る計算は線の端と短い形だけが払う
/// - 2 軸の帯が両方とも画素を切るときは、画素の四角を箱の縁で切って面積を出す
///
/// `unitsPerPixel` は逆行列の行ノルム (`rows` から出したもの)。
///
/// [#2226]: https://github.com/mokume-metal/mokume/issues/2226
static inline float mokume_boxCoverage(float2 at, float2 extent, float2 unitsPerPixel, float4 rows) {
    if (mokume_rowsAlignToPixels(rows)) {
        return mokume_spanCoverage(at.x / unitsPerPixel.x, extent.x / unitsPerPixel.x)
            * mokume_spanCoverage(at.y / unitsPerPixel.y, extent.y / unitsPerPixel.y);
    }
    // 画素の四角が、形の各軸の座標で動く幅の半分
    float2 reach = 0.5 * float2(abs(rows.x) + abs(rows.y), abs(rows.z) + abs(rows.w));
    // どちらかの軸で箱の外なら 0
    if (any(at - reach >= extent) || any(at + reach <= -extent)) { return 0.0; }
    // 画素の四角が、軸ごとの帯に丸ごと入るか (入れば、その軸は何も切らない)
    bool cutsX = at.x - reach.x < -extent.x || at.x + reach.x > extent.x;
    bool cutsY = at.y - reach.y < -extent.y || at.y + reach.y > extent.y;
    if (!cutsX && !cutsY) { return 1.0; }
    if (!cutsY) { return mokume_stripCoverage(at.x, extent.x, rows.xy); }
    if (!cutsX) { return mokume_stripCoverage(at.y, extent.y, rows.zw); }
    float2 poly[10] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5)
    };
    uint n = 4;
    // 軸ごとに、帯の両縁 (画素を切る縁だけ)。`c + g · d ≤ h` は `(h − c) − g · d ≥ 0`
    if (at.x + reach.x > extent.x) { mokume_clipPolygon(poly, n, extent.x - at.x, -rows.xy); }
    if (at.x - reach.x < -extent.x) { mokume_clipPolygon(poly, n, extent.x + at.x, rows.xy); }
    if (at.y + reach.y > extent.y) { mokume_clipPolygon(poly, n, extent.y - at.y, -rows.zw); }
    if (at.y - reach.y < -extent.y) { mokume_clipPolygon(poly, n, extent.y + at.y, rows.zw); }
    float area = 0.0;
    for (uint i = 0; i < n; i++) {
        float2 a = poly[i];
        float2 b = poly[i + 1 == n ? 0 : i + 1];
        area += a.x * b.y - a.y * b.x;
    }
    return 0.5 * abs(area);
}

/// 1 画素より細い**丸い端の線** (カプセル) と、描く画素の正方形の重なりの面積 ([#2991])。`at` は線の中心を
/// 原点にした座標 (形自身の座標)・`halfLength` は半分の長さ・`halfWeight` は太さの半分。
///
/// 細い枝は端を `halfLength + halfWeight` の箱として四角に数えるので、丸い端 (半円) より端 1 つにつき
/// `(2 − π/2) · halfWeight²` (太さ w で約 0.107 · w²) 多く出る — 太さ 1・長さ 1 の破線の片が約 12% 多かった。
/// 回した線の境目が法線向きの幅 (45° で √2) になって、太さ 1〜1.41 の丸い端の線もこの枝に入るので、端が
/// 効くようになった。**半円を、同じ面積の面取り (角を 45° に落とす) で数える**: 四角の端の 4 つの角を、
/// 脚の長さ `c = halfWeight · √(2 − π/2)` の直角二等辺三角形で落とすと、落ちる面積が半円との差に等しい。
/// 半分の長さが太さの半分の 1/4 までは `c` を縮め (長さ 0 の点は四角のまま。境目の幅のつなぎ
/// `mokume_formReachCurved` と同じ割合)、点と長さ 1e-3 の線の間で濃さが跳ばない。
///
/// 面取りで落とす 4 つの三角形のうち、画素に触れるものだけ、画素の正方形を切って面積を出し、箱の被覆から引く
/// (`mokume_boxCoverage` の多角形と同じ道具)。線の中ほどの画素は箱の式のままで、端に掛かる画素だけが払う。
/// **長い線 (半分の長さが描く画素 6 つ以上) は箱のまま** — 端の差は 1 つにつき約 0.107 · w² で、長い線の光の量に対して
/// 1% に満たず、端の画素を数える費用 (斜めの細い線 2,000 本で GPU 時間が 3 割ほど) に見合わない。
/// **形の軸が画素の軸に沿うとき (`mokume_rowsAlignToPixels`) は、従来どおり箱の式を返す** — 軸に沿う線の絵は
/// 1 ビットも動かない (四角の端の線も同じ)。
///
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
static inline float mokume_capsuleCoverage(
    float2 at, float halfLength, float halfWeight, float2 unitsPerPixel, float4 rows)
{
    float2 extent = float2(halfLength + halfWeight, halfWeight);
    float box = mokume_boxCoverage(at, extent, unitsPerPixel, rows);
    // 長い線 (半分の長さが描く画素 6 つ以上) は箱のまま。端の差は 1 つにつき約 0.107 · w² で、長い線の光の量に
    // 対して 1% に満たず、端の画素を数える費用 (斜めの細い線 2,000 本で GPU 時間が 3 割ほど) に見合わない
    if (halfLength >= 6.0 * unitsPerPixel.x) { return box; }
    // 面取りの脚。半分の長さが太さの半分の 1/4 以上なら満額 (割り算は短い線と点のときだけ)
    float chamfer = halfWeight * 0.65524;
    if (halfLength < 0.25 * halfWeight) { chamfer *= saturate(halfLength / max(0.25 * halfWeight, 1e-30)); }
    if (box <= 0.0 || chamfer <= 0.0 || mokume_rowsAlignToPixels(rows)) { return box; }
    // 面取りで落とす 4 つの直角二等辺三角形 (形自身の座標): 角 `(sx · (L + w), sy · w)` で、
    // `sx · x ≤ L + w`・`sy · y ≤ w`・`sx · x + sy · y ≥ b`。箱の被覆から、画素との重なりの面積を引く
    float b = halfLength + 2.0 * halfWeight - chamfer;
    // 画素の |x| + |y| の最大が b 以下なら、どの三角形にも触れない (線の中ほど・画素ごとの安い見切り)
    float2 half4 = 0.5 * float2(abs(rows.x) + abs(rows.y), abs(rows.z) + abs(rows.w));
    if (abs(at.x) + abs(at.y) + half4.x + half4.y <= b) { return box; }
    float lost = 0.0;
    for (uint i = 0; i < 4; i++) {
        float2 n = float2((i == 1 || i == 2) ? -1.0 : 1.0, i >= 2 ? -1.0 : 1.0);
        float2 slope = n.x * rows.xy + n.y * rows.zw;
        float inside = dot(n, at) - b;
        // 面取りの面の外側 (三角形の側) に画素が触れないなら飛ばす
        if (inside + 0.5 * (abs(slope.x) + abs(slope.y)) <= 0.0) { continue; }
        float2 poly[7] = {
            float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5)
        };
        uint count = 4;
        mokume_clipPolygon(poly, count, inside, slope);
        mokume_clipPolygon(poly, count, extent.x - n.x * at.x, -n.x * rows.xy);
        mokume_clipPolygon(poly, count, extent.y - n.y * at.y, -n.y * rows.zw);
        float area = 0.0;
        for (uint j = 0; j < count; j++) {
            float2 p0 = poly[j];
            float2 p1 = poly[j + 1 == count ? 0 : j + 1];
            area += p0.x * p1.y - p0.y * p1.x;
        }
        lost += 0.5 * abs(area);
    }
    return max(box - lost, 0.0);
}

/// 1 画素より細い楕円の塗りの被覆 ([#1477])。`p` と `radii` は形自身の座標、
/// `unitsPerPixel` は描く画素 1 つが形自身の座標でいくらか。
///
/// 描く画素で細い向きも長い向きも両縁を見て数え、`rect` の細い塗りと同じ箱フィルタ
/// (`mokume_boxCoverage`) で画素と重ねる。細い向きの半幅は、**画素の中で楕円の
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
static inline float mokume_thinEllipseCoverage(
    float2 p, float2 radii, float2 unitsPerPixel, float4 rows)
{
    // 描く画素で細い向きを x に揃える (radii.x / u.x ≤ radii.y / u.y を割らずに比べる)
    bool thinIsX = radii.x * unitsPerPixel.y <= radii.y * unitsPerPixel.x;
    float2 at = thinIsX ? p : p.yx;
    float2 r = thinIsX ? radii : radii.yx;
    float2 u = thinIsX ? unitsPerPixel : unitsPerPixel.yx;
    // 画素が長い向きの座標で広がる幅の半分は、回していても行ノルムの半分で取る。四角の角まで
    // 届く幅 (行の絶対値の和の半分) で取ると、いちばん広い所を取る上振れが 45° で増える
    // (長さ 20・太さ 0.5 の楕円で、軸に沿った同じ楕円の +4.7% が +6.7% になった。#2226)。
    // **細い枝の境目 (`reachPerPixel`) も、楕円は行ノルム** (法線が回る曲線・#2991) で、この見積もりと同じ量で
    // 測る — 境目と枝の中が別の量だと、境目の両側で光の量が跳ねる
    float reach = 0.5 * u.y;
    // 画素の中で、長い向きに楕円の中心へいちばん近い位置
    float nearest = clamp(0.0, at.y - reach, at.y + reach);
    float t = min(abs(nearest) / max(r.y, 1e-30), 1.0);
    float halfWidth = r.x * sqrt(max(1.0 - t * t, 0.0));
    // 回していれば、画素の軸に沿った正方形との重なりの面積で数える (`mokume_boxCoverage`)
    return mokume_boxCoverage(
        p, thinIsX ? float2(halfWidth, r.y) : float2(r.y, halfWidth), unitsPerPixel, rows);
}

/// 1 画素より細い楕円の輪郭の帯の穴の被覆 ([#2186])。`p`・`radii` は形自身の座標
/// (`p` は輪郭の位置での座標)、`hole` は `mokume_ellipseHole` の返り値。
///
/// 1 画素より細い楕円の塗り (`mokume_thinEllipseCoverage`) と同じ箱フィルタで、短い向きと
/// 長い向きの重なりの長さを取る (回していれば `mokume_boxCoverage` で画素の四角との面積にする・#2226)。
/// 長い向きは穴の端 (`hole`) までの帯、短い向きの半幅は
/// **画素の中で中心にいちばん近い長い軸の上の点 x での穴の半幅** `D(x) − 太さの半分` を取る。
/// `D(x)` は長い軸の上の点から縁までの真の距離で、縮閉線の尖りの内 (`x · 長半径 < 長半径² −
/// 短半径²`) では `短半径 · √(1 − x² / (長半径² − 短半径²))`、外では先端までの `長半径 − x` である。
///
/// 穴を楕円とみなすと、太い輪郭で尖った穴の端の近くを太く数えすぎる (`ellipse(0, 0, 40, 2.4)`・
/// 太さ 2 で、帯に丸ごと入る画素に 16% の欠けが残った。CPU の写し)。円は長い軸の上の点の
/// 距離が `半径 − x` になり、穴は外接する四角で数える (細い塗りの円と同じ数え方)。
///
/// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
static inline float mokume_thinEllipseHoleCoverage(
    float2 p, float2 radii, float halfWeight, float2 hole, float2 unitsPerPixel, float4 rows)
{
    // 短い向きを x に揃える
    bool shortIsX = radii.x <= radii.y;
    float2 at = shortIsX ? p : p.yx;
    float2 r = shortIsX ? radii : radii.yx;
    float2 h = shortIsX ? hole : hole.yx;
    float2 u = shortIsX ? unitsPerPixel : unitsPerPixel.yx;
    float nearest = abs(clamp(0.0, at.y - 0.5 * u.y, at.y + 0.5 * u.y));
    // 縮閉線の尖りの位置 (長半径² − 短半径²) / 長半径。円では 0 で、先端までの距離を取る
    float spread = r.y * r.y - r.x * r.x;
    float depth = nearest * r.y < spread
        ? r.x * sqrt(max(1.0 - nearest * nearest / max(spread, 1e-30), 0.0))
        : r.y - nearest;
    float halfWidth = max(depth - halfWeight, 0.0);
    // 回していれば、画素の軸に沿った正方形との重なりの面積で数える (`mokume_boxCoverage`・#2226)
    return mokume_boxCoverage(
        p, shortIsX ? float2(halfWidth, max(h.y, 0.0)) : float2(max(h.y, 0.0), halfWidth),
        unitsPerPixel, rows);
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

/// 原点を中心とする、角を半径 `radius` で丸めた箱の距離場 ([#2757])。
///
/// **角丸の箱は、半幅を `radius` だけ縮めた箱を `radius` だけ膨らませた形** なので、縮めた箱の
/// 距離場から `radius` を引くだけで出る。外では角の円弧の中心 (縮めた箱の角) へ向かう向き、
/// 内では近い辺の向きの勾配が、そのまま真の距離場の勾配になる。`radius` は半幅・半高の小さい
/// ほう以下 (CPU が締める) で、縮めた箱の半幅が負にならない。
///
/// **`radius` が 0 のときは `mokume_boxField` と同じ値を返す** (0 を引くだけ)。角を丸めない
/// 矩形の絵は変わらない。
///
/// [#2757]: https://github.com/mokume-metal/mokume/issues/2757
static inline FormField mokume_roundedBoxField(float2 p, float2 extent, float radius) {
    FormField field = mokume_boxField(p, extent - radius);
    field.distance -= radius;
    return field;
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

/// 原点を中心とする楕円の**真の**符号つき距離場 (内で負・[#2742])。`mokume_ellipseField` は
/// 縁から離れると真の距離からずれるが、こちらは縁から遠い所でも厳密である。反復があるので、
/// 近似では輪郭の帯の位置がずれすぎる楕円だけが使う (`mokume_needsExactRing`・`ringFromFill`)。
///
/// 解き方は D. Eberly の "Distance from a Point to an Ellipse" で、第 1 象限の点 (長い軸を x に
/// 揃える) から縁までのいちばん近い点を、乗数 `t` の方程式
/// `g(t) = (r · zx / (t + r))² + (zy / (t + 1))² − 1 = 0` の根で出す。`z = p / 半径`、`r` は
/// (長半径 / 短半径)²。根は `t > zy − 1` にただ 1 つで、`g` はそこで**凸で単調に減る**ので、
/// 左側 (`g > 0`) から始めるニュートン法は、行き過ぎずに単調に根へ近づく。
///
/// **`u = t + 1` で解く。** `t` のままだと、長軸の近くの点 (`zy` が 0 に近い) で根が −1 の
/// すぐ上に来て、32 bit の浮動小数点では `t + 1` が表せない。`u` なら 0 に近い値も表せる。
/// 外の点は `u = 1` (縁の上の点の根) が左側にあたり、内の点は下限の `zy` から始める。
/// 長軸の上の点 (`zy = 0`) は、縮閉線の尖りの内側では軸の外に最も近い点が 2 つあり、
/// 軸の上に根が無い (0/0) ので、`zy` を 1e-12 で押さえる — 根は `u ≈ zy` の近くに出て、
/// 最も近い点は軸の外の 1 つ (上側) になる。距離は 2 つで同じ。
///
/// **反復は、1 回の動きが `u` の 1e-4 に収まったら止め、多くても 16 回。** 縁の近くの点は 4 回
/// (中央値)・8 回 (99%) ほどで収まる。短半径 / 長半径が 0.001〜0.99999 の楕円で、縁から太さの半分 + 1.5
/// 画素の内の点を走査し (ほぼ円の楕円は太さの半分が短半径の 0.4 倍までの太い輪郭も)、32 bit で真の
/// 距離 (64 bit の二分法) との差が 2.3e-5 以内に収まった (固定 10 回では 1.0 がずれる点が出た)。
///
/// 返す勾配は、いちばん近い縁の点での外向きの法線 (長さ 1)。
static inline FormField mokume_ellipseExactField(float2 p, float2 radii) {
    // 長いほうを x に揃え、第 1 象限へ折る
    bool swapped = radii.x < radii.y;
    float a = max(swapped ? radii.y : radii.x, 1e-6);
    float b = max(swapped ? radii.x : radii.y, 1e-6);
    float2 folded = abs(swapped ? p.yx : p);
    float zx = folded.x / a;
    float zy = max(folded.y / b, 1e-12);
    // 長半径 / 短半径の 2 乗から 1 を引いたもの (桁落ちを避けて積で出す)
    // 比が約 1.8e19 を越えると 32 bit であふれて NaN になるので、1e30 で押さえる (その比の楕円は
    // 線分とみなせ、根は `u ≈ zy` の近くに出る)
    float m = min((a - b) * (a + b) / (b * b), 1e30);
    float n0 = (1.0 + m) * zx;
    bool inside = zx * zx + zy * zy <= 1.0;
    // 根より左の点から始める。`g` は `u < zy` でも `u + m < n0` でも正 (どちらかの項が 1 を越える)
    // ので、`zy` と `n0 − m` のどちらも根の左にある。内の点は `zy` だけだと、ほぼ円の楕円
    // (`m` が小さい) の長軸の近くで根が `zy` よりずっと右にあり、ニュートン法が 16 回で収まらず
    // 大きく外れた (`a = 100, b = 99.9, h = 37.8` の `y = 0` で誤差 9.8)。`n0 − m` は根の近くから始める。
    // 外の点は縁の上の点の根 `u = 1` が左側にあたる
    float u = max(inside ? zy : 1.0, max(zy, n0 - m));
    for (int i = 0; i < 16; i++) {
        float ua = n0 / (u + m);
        float ub = zy / u;
        float g = ua * ua + ub * ub - 1.0;
        float slope = min(-2.0 * (ua * ua / (u + m) + ub * ub / u), -1e-30);
        float next = max(u - g / slope, zy);
        bool done = abs(next - u) <= 1e-4 * next;
        u = next;
        if (done) { break; }
    }
    // いちばん近い縁の点を単位円の点 (ua, ub) で持つ
    float ua = n0 / (u + m);
    float ub = zy / u;
    float distance = length(float2(a * ua - folded.x, b * ub - zy * b));
    float2 normal = mokume_direction(float2(ua / a, ub / b), float2(1.0, 0.0));
    // 折った分を戻す
    float2 signs = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    normal = swapped ? normal.yx : normal;
    return mokume_field(inside ? -distance : distance, normal * signs);
}

/// 点 `a` から点 `b` へ引いた線分までの距離場 (符号なし)。扇の 2 本の半径は `a` が原点、弦は `a`・`b` が弧の両端。
static inline FormField mokume_segmentBetween(float2 p, float2 a, float2 b) {
    float2 along = b - a;
    float h = saturate(dot(p - a, along) / max(dot(along, along), 1e-12));
    float2 away = p - (a + along * h);
    // **控えの向きも長さ 1 に揃える。** 線分の上に乗った点では `away` が 0 になって控えが
    // 使われるが、`along` は線分の長さ (扇の半径は半径ぶん) なので、揃えないと
    // この節の他の距離関数と違い 1 ではない。長さがそのまま `mokume_formCoverage` の「画素あたり
    // 距離がいくら進むか」に化けるので、渡しが半径の倍だけ間延びし、扇の直線の縁では
    // **輪郭の帯の真ん中の 1 画素だけが薄く抜ける** ([#752](https://github.com/mokume-metal/mokume/issues/752))
    float2 fallback = mokume_direction(float2(-along.y, along.x), float2(0.0, 1.0));
    return mokume_field(length(away), mokume_direction(away, fallback));
}

/// 原点から `end` へ引いた線分までの距離場 (符号なし)。
static inline FormField mokume_segmentField(float2 p, float2 end) {
    return mokume_segmentBetween(p, float2(0.0), end);
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
/// 2 本の半径は原点から弧の端までの**線分**として距離を取り、楕円の縁は**楕円への最近点が弧の
/// 角の範囲にあるときだけ**数える (扇の内外では決めない・下の本体と [#2914])。角の外側は
/// 真の距離になるので半径 hw で丸く出る。
///
/// `directions` は始まりと終わりの角の向き `(cos, sin)` 2 組 (`mokume_sectorDirections`)。
///
/// `chord` が真なら、扇でなく**弧の両端を弦で結んだ形** (`kArcChord`・`kArcOpen` の塗りと `kArcChord` の輪郭の周)
/// の距離場になる ([#2428](https://github.com/mokume-metal/mokume/issues/2428))。辺は 2 本の半径でなく 1 本の弦で、
/// 内外は弦の直線 (`chordLine`・`mokume_chordLine`) の弧の側かどうか。弧の候補の数え方 (楕円への最近点が弧の角の
/// 範囲にあるときだけ) は扇と同じ。
///
/// `exact` は、楕円の弧の距離場を近似 (`mokume_ellipseField`) ではなく真の距離
/// (`mokume_ellipseExactField`) で出すか。近似の距離場がずれすぎる細長い楕円の扇の輪郭だけ真で、
/// 塗りは近似のまま ([#2747](https://github.com/mokume-metal/mokume/issues/2747))。
///
/// [#2914]: https://github.com/mokume-metal/mokume/issues/2914
static inline FormField mokume_arcRegionField(
    float2 p, float2 radii, float4 directions, float sweep, bool exact, bool chord, float4 chordLine)
{
    // 弧の両端。2 本の辺も内外の判定もこの 2 点から作る。向きは頂点関数が 1 度だけ求めて渡す
    // (`directions`・`mokume_sectorDirections`。画素ごとに三角関数を解かない・#2384)
    float2 direction1 = directions.xy;
    float2 direction2 = directions.zw;
    float2 end1 = radii * direction1;
    float2 end2 = radii * direction2;
    bool inWedge;
    FormField nearest;
    if (chord) {
        // **弦で結んだ形** (#2428): 辺は弧の両端を結ぶ 1 本の線分で、内外の判定は弦の直線の弧の側かどうか。
        // 掃引が π を越えても同じ式で、弧の側は広いほうになる (`mokume_chordLine`)。弧の候補は下と同じ
        inWedge = dot(p, chordLine.xy) >= chordLine.z;
        nearest = mokume_segmentBetween(p, end1, end2);
    } else {
        // 中心から弧の端へ向かう半直線を含む半平面。内側 (扇の中) で負になる向きに取る。
        // **符号しか使わない** (距離は下の線分と楕円で画素のまま測る) ので、法線の長さは
        // 揃えない。符号は (x/rx, y/ry) の空間で単位円の扇を切る半平面と同じ — 掃引 t の
        // 扇がそこでも掃引 t なので、π で「かつ / または」を切り替える判定もそのまま使える
        float halfPlane1 = dot(p, float2(end1.y, -end1.x));
        float halfPlane2 = dot(p, float2(-end2.y, end2.x));
        inWedge = sweep <= M_PI_F
            ? (halfPlane1 <= 0.0 && halfPlane2 <= 0.0)
            : (halfPlane1 <= 0.0 || halfPlane2 <= 0.0);
        FormField edge1 = mokume_segmentField(p, end1);
        FormField edge2 = mokume_segmentField(p, end2);
        nearest = edge1.distance < edge2.distance ? edge1 : edge2;
    }
    FormField ellipse = exact ? mokume_ellipseExactField(p, radii) : mokume_ellipseField(p, radii);
    // **弧を候補に入れるのは、楕円への最近点が弧の角の範囲にあるときである。扇の内外 (`inWedge`) では
    // 決めない** ([#2914](https://github.com/mokume-metal/mokume/issues/2914))。楕円では最近点の向き
    // (法線) が中心から見た向きとずれるので、扇の内でも最近点が弧の外にあり (範囲の外の弧まで距離を
    // 測って、帯が外へ滲む)、扇の外でも最近点が弧の内にある (弧が最も近いのに線分への距離を返して、
    // 帯が欠ける)。最近点の媒介変数 t は、`p` から縁の足 `p − 距離 · 勾配` (勾配は最近点での外向きの
    // 法線) を引いて半径で割った向き `(cos t, sin t)` で測る。**近似の距離場 (`exact` でない枝) も
    // 同じ式で測る**: 近似の勾配は中心から見た向き (`p / 半径²`) で、`inWedge` と同じ向きになるので、
    // 勾配だけで測ると、扇の内外の判定と同じずれが残る (輪郭の帯の縁は縁から太さの半分離れていて、
    // 弧の端の近くで足の向きがずれる)。近似の距離は縁の近くで 1 次の精度があるので、足は 1 画素の内で
    // 2 次の誤差で、距離の値そのものは近似のまま。範囲の外の最近点は、弧の端 (2 本の辺の端) が受け持つ
    float2 onArc = (p - ellipse.distance * ellipse.gradient) / radii;
    float arcSide1 = dot(onArc, float2(direction1.y, -direction1.x));
    float arcSide2 = dot(onArc, float2(-direction2.y, direction2.x));
    bool nearestOnArc = sweep <= M_PI_F
        ? (arcSide1 <= 0.0 && arcSide2 <= 0.0)
        : (arcSide1 <= 0.0 || arcSide2 <= 0.0);
    if (nearestOnArc && abs(ellipse.distance) < nearest.distance) {
        nearest = mokume_field(abs(ellipse.distance), ellipse.gradient);
    }
    bool inside = inWedge && ellipse.distance < 0.0;
    return mokume_field(inside ? -nearest.distance : nearest.distance, nearest.gradient);
}

/// 楕円の輪郭の帯の穴 (内縁の内) が画素に占める面積を、画素の中の 8×8 の標本で数える
/// ([#2742](https://github.com/mokume-metal/mokume/issues/2742))。標本は真の距離
/// (`mokume_ellipseExactField`) が内縁の内に入るかで決める。
///
/// 太さの半分が長い軸の端の曲率半径を越える楕円の穴は、端が尖る。縁 1 本の距離場は尖りの先の画素で
/// 穴の片方の縁しか見ず、両縁を見る積 (`mokume_thinEllipseHoleCoverage`) は穴を長方形で数えて過大に
/// なる。そこで、穴の端に近い画素 (尖りの先だけ) の面積を、標本で数え直す。穴から画素の半対角より
/// 離れた画素は標本を取らずに 0 と 1 を返す。費用は尖りの先の画素だけが払う。標本は 8×8 (16×16 では
/// 部分被覆の外れが 2.3% まで縮むが、細長い楕円 200 個の GPU 時間が 3.5 倍になった。8×8 は 2.0 倍で、
/// 外れは最悪 6.6%)。
static inline float mokume_ellipseHoleSampled(
    float2 q, float2 radii, float halfWeight, float4 inverseRows)
{
    float reach = 0.5 * length(float2(
        abs(inverseRows.x) + abs(inverseRows.y), abs(inverseRows.z) + abs(inverseRows.w)));
    float margin = mokume_ellipseExactField(q, radii).distance + halfWeight;
    if (margin > reach) { return 0.0; }
    if (margin < -reach) { return 1.0; }
    const int n = 8;
    int inside = 0;
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            float2 offset = (float2(i, j) + 0.5) / float(n) - 0.5;
            float2 at = q + float2(dot(inverseRows.xy, offset), dot(inverseRows.zw, offset));
            if (mokume_ellipseExactField(at, radii).distance + halfWeight < 0.0) { inside++; }
        }
    }
    return float(inside) / float(n * n);
}

/// 扇の輪郭の帯の穴 (内縁の内) が画素に占める面積 (0〜1)。穴が潰れているか 1 画素より細い扇の
/// 内縁を数える ([#2747](https://github.com/mokume-metal/mokume/issues/2747))。
///
/// **縁 1 本の距離場は、細い穴の向こう側の縁を見られない。** 穴が潰れている (扇の内接円の半径の
/// 上限 `depthBound` が太さの半分以下) と、内縁は「どこにも無い」はずなのに、被覆が縁の渡し (1 画素)
/// の内に残って帯が欠ける (`arc(0, 0, 20, 20, 0, π)`・太さ 10.4 で 18.8%)。穴が 1 画素より細いと、
/// 穴の両端が鋭く尖り (内縁を作る 2 つの縁が鋭い角で交わる)、尖りの先の画素に穴の距離が小さいまま
/// 長く残って、穴から離れた画素まで被覆が残る (半円・太さ 19 の穴の端で、穴から 0.6 画素離れた画素に
/// 28%)。rect と楕円は穴を長方形で数えるが、扇の穴は形が 1 つの式で書けない (内接円の半径が掃引で
/// 決まり、穴は弧と 2 本の半径の 3 つの縁に囲まれる) ので、**画素の中を格子で標本して、内縁の内に入る
/// 標本の割合で数える**。穴から画素の半対角より離れた画素は、標本を取らずに 0 と 1 を返す。
///
/// 標本は 8×8 (楕円の尖りの先と同じ・1 標本 = 1.6%。16×16 は 1 標本が表示の 1 段になるが、GPU 時間がかさむ。楕円の尖りの先では全体で 3.5 倍になった)。穴に掛かる画素は細い穴の周りのごく一部で、費用は
/// 穴が細いか潰れた扇を含む列だけが払う (`kFormHasThinFill`)。
static inline float mokume_sectorHoleCoverage(
    float2 q, float2 radii, float4 directions, float sweep, float halfWeight, float depthBound,
    float4 inverseRows, bool exact, bool chord, float4 chordLine)
{
    if (depthBound <= halfWeight) { return 0.0; }
    // 描く画素の半対角を、形自身の座標で上から抑えた長さ。距離場は 1-リプシッツなので、中心の値が
    // これより離れていれば画素全体が穴の外 (内) にある
    float reach = 0.5 * length(float2(
        abs(inverseRows.x) + abs(inverseRows.y), abs(inverseRows.z) + abs(inverseRows.w)));
    float margin = mokume_arcRegionField(q, radii, directions, sweep, exact, chord, chordLine).distance
        + halfWeight;
    if (margin > reach) { return 0.0; }
    if (margin < -reach) { return 1.0; }
    const int n = 8;
    int inside = 0;
    for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
            float2 offset = (float2(i, j) + 0.5) / float(n) - 0.5;
            float2 at = q + float2(dot(inverseRows.xy, offset), dot(inverseRows.zw, offset));
            if (mokume_arcRegionField(at, radii, directions, sweep, exact, chord, chordLine).distance
                + halfWeight < 0.0)
            {
                inside++;
            }
        }
    }
    return float(inside) / float(n * n);
}

/// 直交する 2 枚の半平面 (`q.x ≤ 0` は `axisX` が外を向く側、`q.y ≤ 0` は `axisY` が外を向く側) の共通部分の距離場。
/// `q` は各半平面の符号つき距離 (外が正)。外側の角は丸い (箱の距離場 `mokume_boxField` と同じ)。
static inline FormField mokume_cornerField(float2 q, float2 axisX, float2 axisY) {
    if (q.x > 0.0 || q.y > 0.0) {
        float2 outside = max(q, 0.0);
        return mokume_field(length(outside), mokume_direction(axisX * outside.x + axisY * outside.y, axisX));
    }
    return q.x > q.y ? mokume_field(q.x, axisX) : mokume_field(q.y, axisY);
}

/// 開いた弧の帯 (`kArcStandard`・`kArcOpen` の輪郭) の外縁の距離場 (内で負)。**帯は弧の中心線から太さの半分
/// までの所で、閉じた周ではないので内縁 (穴) が無い。** 両端の形は `cap` (`kFormCap*`) が決める
/// ([#2428](https://github.com/mokume-metal/mokume/issues/2428))。
///
/// - **round**: 弧までの距離。楕円への最近点が弧の角の範囲 (`footOnArc`) にあれば楕円の距離、範囲の外なら
///   近いほうの端の点までの距離 (扇と同じ数え方・[#2914]) で、両端が丸くなる
/// - **square** (線の長さちょうどで切る): 帯を、両端の法線で切る。切り口は端を通り接線に垂直な直線で、
///   最近点がどちらの端の側にあるか (弧の真ん中の向きとの外積の符号) でその直線を選ぶ。**楕円の帯でも
///   端の切り口の位置は厳密** (端の法線の直線が帯の両縁と直角に交わる)
/// - **project** (線の長さに半分の太さを足す): square の帯に、端から接線の向きに半分の太さだけ出る長方形
///   (幅は太さ) を足す (距離場の和集合)。長方形は弧に沿って曲がらず、まっすぐ出る — 太い線で小さな円弧を
///   引いても、端は弧の延長でなく接線の延長になる
///
/// `isThin` / `thinCoverage` は、帯が描く画素で 1 画素より細いとき (`2 · 太さの半分 < 画素の法線向きの幅`・
/// 線の細い枝と同じ境目) に、縁 1 本の距離場の代わりに**両縁を見る**被覆 (帯の被覆 × 端の切り口の被覆) を返す
/// (`mokume_stripCoverage`)。縁 1 本の距離場は細い帯を過大に数える ([#1451])。project の細い帯は長方形を
/// 足さず、切り口を太さの半分だけ外へずらして数える (細い帯では差が画素に見えない)。**丸い端の先は帯のまま
/// 数える** (半径が太さの半分の円板より端で多く出るが、端の 1 画素ぶんである)。
///
/// [#2914]: https://github.com/mokume-metal/mokume/issues/2914
/// [#1451]: https://github.com/mokume-metal/mokume/issues/1451
static inline FormField mokume_arcBandField(
    float2 p, float2 radii, float4 directions, float2 middle, float sweep, bool exact,
    float halfWeight, uint cap, float4 rows, thread bool &isThin, thread float &thinCoverage)
{
    float2 direction1 = directions.xy;
    float2 direction2 = directions.zw;
    float2 end1 = radii * direction1;
    float2 end2 = radii * direction2;
    FormField ellipse = exact ? mokume_ellipseExactField(p, radii) : mokume_ellipseField(p, radii);
    // 楕円への最近点 (媒介変数の空間)。弧の角の範囲にあるかの判定は `mokume_arcRegionField` と同じ式
    float2 foot = (p - ellipse.distance * ellipse.gradient) / radii;
    float footSide1 = dot(foot, float2(direction1.y, -direction1.x));
    float footSide2 = dot(foot, float2(-direction2.y, direction2.x));
    bool footOnArc = sweep <= M_PI_F
        ? (footSide1 <= 0.0 && footSide2 <= 0.0)
        : (footSide1 <= 0.0 || footSide2 <= 0.0);
    // 楕円までの距離 (符号なし) と、そこから離れる向き
    float2 ringNormal = ellipse.distance < 0.0 ? -ellipse.gradient : ellipse.gradient;
    FormField reach = mokume_field(abs(ellipse.distance), ringNormal);

    // 端の切り口。最近点が弧の真ん中から終わりの側にあれば終わりの端、始まりの側なら始まりの端が受け持つ
    // (弧の外の隙間では、隙間の真ん中で分ける)
    bool towardEnd2 = middle.x * foot.y - middle.y * foot.x > 0.0;
    float2 tangent1 = mokume_direction(radii * float2(-direction1.y, direction1.x), float2(0.0, 1.0));
    float2 tangent2 = mokume_direction(radii * float2(-direction2.y, direction2.x), float2(0.0, 1.0));
    float2 capEnd = towardEnd2 ? end2 : end1;
    float2 capOutward = towardEnd2 ? tangent2 : -tangent1;
    // 端の法線の直線までの距離は、端の近くでだけ意味を持つ。楕円では、端の法線の直線が中心を通らず、
    // 弧の反対側の遠い画素が、弧の側に見えて切り口の内側に入ってしまう (帯の幻が弧の外の隙間に出る)。だから:
    // - 最近点が弧の外なら、端の点までの距離から太さの半分を引いた値も下限にする (切り口の正しい位置では
    //   平面の距離のほうが大きいので変わらない: 端から平面に沿って u、法線の向きに c 進んだ画素の端の点までの距離は
    //   √(c² + u²) ≤ c + 太さの半分)
    // - 最近点が弧の中なら、端の点から遠い画素は切り口と関係が無いので使わない
    // **「端の近く」の幅は画素の大きさ (描く画素 1 つが形の座標でいくつか) で測る。** 形の座標の定数にすると、
    // 縮めて描く場面 (`scale(0.05)`) では端の角の画素が圏外になって切り口が効かず、拡げて描く場面
    // (`scale(400)`) では守りが一度も効かない。切り口の位置の画素は、端から太さの半分の所の帯の角で、
    // 縁の被覆が広がる幅 (半画素寄せ + 斜めの画素の半分の対角 ≈ 1.2 画素) より余裕を持って 2 画素を取る
    float pixel = max(length(rows.xy), length(rows.zw));
    float toCapEnd = length(p - capEnd);
    float capPlane = dot(p - capEnd, capOutward);
    float capDistance = footOnArc
        ? (toCapEnd < halfWeight + 2.0 * pixel ? capPlane : -1e6)
        : max(capPlane, toCapEnd - halfWeight);

    if (cap == kFormCapRound && !footOnArc) {
        // 最近点が弧の外: 近いほうの端の点までの距離 (両端の丸い先)
        float2 toEnd1 = p - end1;
        float2 toEnd2 = p - end2;
        float distance1 = length(toEnd1);
        float distance2 = length(toEnd2);
        reach = distance1 <= distance2
            ? mokume_field(distance1, mokume_direction(toEnd1, ringNormal))
            : mokume_field(distance2, mokume_direction(toEnd2, ringNormal));
    }

    // 帯が描く画素で 1 画素より細いか。画素の法線向きの幅は、距離場の勾配を画面へ写した長さ
    // (`mokume_formCoverage`)。細ければ両縁を見る被覆を返す
    isThin = false;
    thinCoverage = 0.0;
    if (kFormHasThinFill) {
        float2 screen = float2(
            rows.x * reach.gradient.x + rows.z * reach.gradient.y,
            rows.y * reach.gradient.x + rows.w * reach.gradient.y);
        if (2.0 * halfWeight * (1.0 + 2.0 * kFormSnap) < length(screen)) {
            isThin = true;
            float strip = mokume_stripCoverage(reach.distance, halfWeight, screen);
            float cut = 1.0;
            if (cap != kFormCapRound) {
                float shift = cap == kFormCapProject ? halfWeight : 0.0;
                cut = mokume_formCoverage(mokume_field(capDistance - shift, capOutward), rows, false);
            }
            thinCoverage = strip * cut;
        }
    }

    if (cap == kFormCapRound) { return mokume_field(reach.distance - halfWeight, reach.gradient); }
    FormField band = mokume_cornerField(
        float2(reach.distance - halfWeight, capDistance), reach.gradient, capOutward);
    if (cap == kFormCapProject) {
        // 端から接線の向きに半分の太さだけ出る長方形 (幅は太さ)。2 つの端の両方を足す。**帯とは距離場の和集合
        // (小さいほう) で合わせる** — 被覆を足し算で重ねると、ほぼ一周の弧 (隙間が太さより狭く、長方形どうしや
        // 反対の端の帯と重なる) で縁の画素を和で数えて過大になる。真の被覆は和集合である。
        //
        // 和集合にすると、帯の切り口と長方形の辺が同じ直線の上で接する継ぎ目の画素が、どちらの縁も半分ずつ数えて
        // 0.5 になる。**長方形を切り口の内側へ 1 画素ぶん延ばして重ねて潰す** (延ばした所は帯の中なので形は変わらない。
        // 帯の外へはみ出すのは、弧が接線から離れる分 `(1 画素)² / 2 半径` だけで、半径が数画素あれば 0.1 画素に満たない)
        float overlap = pixel;
        for (uint end = 0; end < 2; end++) {
            float2 point = end == 0 ? end1 : end2;
            float2 direction = end == 0 ? direction1 : direction2;
            float2 outward = end == 0 ? -tangent1 : tangent2;
            float2 normal = mokume_direction(direction / radii, float2(1.0, 0.0));
            float2 relative = p - point;
            float boxLength = halfWeight + overlap;
            float along = dot(relative, outward) - 0.5 * (halfWeight - overlap);
            float sideways = dot(relative, normal);
            FormField box = mokume_cornerField(
                float2(abs(sideways) - halfWeight, abs(along) - 0.5 * boxLength),
                normal * (sideways < 0.0 ? -1.0 : 1.0), outward * (along < 0.0 ? -1.0 : 1.0));
            if (box.distance < band.distance) { band = box; }
        }
    }
    return band;
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
    /// 画素の中で塗りと輪郭の帯が重なる面積 `o` (塗りと輪郭を両方持つ形だけ。ほかは 0)。
    /// 見積もるのは割り戻す前の塗りの被覆率からである
    float overlap;
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
/// 偽なら、塗りだけの形と輪郭だけの形を別々に出したのと同じ被覆率になる。どちらでも、塗りと
/// 輪郭を両方持つ形には、画素の中で塗りと帯が重なる面積 `o` (`FormPaint.overlap`) も出す —
/// 偽の入口 (下地を読む断片) は、それで画素を 4 つの面積に分けて混ぜる (`mokume_formFragment`)。
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
    // `inverseRows` の行ノルムになる (`mokume_formCoverage` の説明で n を軸に取ったもの。細い枝の
    // 境目は、直線の縁の形ではこれではなく下の `reachPerPixel` で測る)。
    // 線では x が長さの向き、y が太さの向きになる。描く画素で測るので、細かさ 0.5 の面の
    // 太さ 1 の線は、描く画素で太さ 0.5 の線として線の細い枝を通る (#1488)
    float2 unitsPerPixel = float2(length(in.inverseRows.xy), length(in.inverseRows.zw));
    // 細い枝の境目は、**縁の形で分けた幅** (`mokume_reachPerPixel`・#2991) で測る: `rect`・線 (直線の縁) は
    // 画素の法線向きの幅 (画素の正方形を形自身の軸へ射影した幅・45° で行ノルムの √2 倍)、円・楕円・扇・
    // 丸い点 (法線が回る曲線) は、向きによらない `unitsPerPixel` と同じ行ノルム。軸に沿う形では
    // どちらも行ノルムと同じ値 (頂点関数がインスタンスごとに 1 度だけ出す。断片で出すと面を覆う塗りの費用が増える)
    float2 reachPerPixel = in.reachPerPixel;
    // 縁の被覆の数え方 (`kCoverage*`・縁の分類の表が決める)。縁 1 本ごとに、線形の渡しのまま返すか
    // 面積で数えるかを下の 3 つが持つ。**軸に沿う `rect` の曲がった部分 (角丸の角・丸い折れ目・削ぎ) と
    // 回した丸い端の線の端は、画素がその領域にあるときだけ切り替える** — 同じ図形の直線の辺・尖った角は
    // 従来の式のまま
    uint coverageMode = in.coverageMode;
    bool fillLinear = coverageMode == kCoverageLinear;
    bool outerLinear = fillLinear;
    bool innerLinear = fillLinear;

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
    // 輪郭の帯の穴 (内縁の内) が画面で 1 画素より細いか潰れているときも同じ (`mokume_thinHole`)
    bool isThinHole = false;
    float thinHoleCoverage = 0.0;
    // 帯の穴の被覆の上限。穴の端が尖る楕円 (`mokume_ellipseExactField` で数える、太さの半分が長い軸の
    // 端の曲率半径を越える楕円) の内縁は、縁 1 本では端の先を数えすぎる (#2742)。1 のときは何もしない
    float holeCap = 1.0;
    // 上の上限が効く画素 (穴の尖りの先) の穴の面積を、標本で数え直すか (#2742)
    bool sampleCuspHole = false;
    if (kind == kFormRect) {
        float2 extent = form.size.xy;
        // 角の半径 (#2757)。0 なら従来の箱と同じ式を通る
        float cornerRadius = form.size.w;
        if (kFormHasFill) {
            fill = mokume_roundedBoxField(p, extent, cornerRadius);
            // 軸に沿う角丸の `rect` の塗りは、全体を面積で数える (辺の画素では、軸に沿う辺の面積と線形の渡しは同じ値)。
            // 領域で切り替えない — 切り替える式を足すと、回した面を覆う塗りの GPU 時間が 14% 増えた
            if (kFormHasThinFill
                && any(2.0 * extent * (1.0 + 2.0 * kFormSnap) < reachPerPixel)) {
                // **画面で 1 画素より細い塗りは、両縁を見る 1 次元の被覆の積で数える**
                // ([#1477](https://github.com/mokume-metal/mokume/issues/1477))。
                // 距離場は縁 1 本しか持たないので、帯の両縁が同じ画素に入ると向こう側の縁の
                // 欠けを引けない — 幅 0.1・高さ 20 の `rect` (面積 2) の和が、帯の中心を画素の
                // 中心に置くと 11.0、画素の境目に置くと 1.86 と、置く位置で 6 倍揺れていた。
                // 塗りは寄せない (ADR-0039 決定 2) ので `q` ではなく `p` で数える。
                //
                // 数え方も境目も、1 画素より細い線の枝と同じにする。画素と箱の重なりを取る
                // (箱フィルタ) ので、濃さは置く位置によらず面積に比例する。形の軸が画素の軸に
                // 沿うときは、細い向きと長い向きで重なる長さを取って掛け合わせる。**沿わない
                // (回した・剪断した) ときは、画素の軸に沿った正方形を箱の縁で切って面積を出す**
                // (`mokume_boxCoverage`・#2226)。形の軸で長さの積を取ると、画素を形の向きに
                // 回した正方形で数えることになり、45° で置く位置により 0.7〜1.4 倍に振れた。
                //
                // **1/256 の遊び (`mokume_formCoverage`) は掛けない。** 両縁に掛けると細い帯
                // ほど効きが大きくなる (幅 0.05 の帯が画素の境目をまたぐと 15% 足りなくなる)。
                //
                // **境目は 1 画素ちょうどではなく 256/258 画素に置く** (線の枝と同じ理由)。
                // 測るのは描く画素の法線向きの幅 (`reachPerPixel`・`rect` は直線の縁なので 45° で √2。
                // #2991)。軸に沿う形では行ノルムのままなので、幅 1 の塗りは丸め (1e-7 ほど) で境目を
                // またがない。それより太い塗りは縁 1 本の式 (斜めの縁は面積で数える) で、軸に沿う形の
                // 絵は 1 ビットも変わらない。
                //
                // **細い塗りを含まない列では、枝ごと原稿から外す** (`kFormHasThinFill`)
                isThinFill = true;
                thinFillCoverage = mokume_boxCoverage(p, extent, unitsPerPixel, in.inverseRows);
            }
        }
        if (kFormHasStroke) {
            // 角の形は外縁だけが持つ。内縁は帯が重なって必ず直角 (三角形のときと同じ)。
            // **角を丸めた矩形の周には折れ目が無い** (弧は辺に接して繋がる) ので、折れ目の形は
            // 読まない — 外縁は丸めた周を太さの半分だけ広げた、半径が `r + 太さの半分` の弧になる
            // (#2757)
            if (form.meta.z == kFormJoinRound || cornerRadius > 0.0) {
                outer = mokume_grown(mokume_roundedBoxField(q, extent, cornerRadius), halfWeight);
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
                    // 削ぎは角の領域 (箱の角の外) だけ。辺と、削ぎの外の箱の角は線形のまま
                }
            }
            // 内縁 (帯の穴) は、形を太さの半分だけ縮めた箱。線幅が形より太いと半幅が負になり、
            // 内縁は「どこにも無い」(被覆 0) になる — 帯が重なって全部塗られる、三角形のときと
            // 同じ絵。**穴が描く画素で 1 画素より細いか潰れているときは、両縁を見る積で数える**
            // (頂点関数が決める `thinHole`・`mokume_thinHole` の説明・
            // [#2186](https://github.com/mokume-metal/mokume/issues/2186))
            float2 hole = extent - halfWeight;
            if (kFormHasThinFill && in.thinHole != 0) {
                isThinHole = true;
                thinHoleCoverage =
                    mokume_boxCoverage(q, max(hole, 0.0), unitsPerPixel, in.inverseRows);
            } else {
                // 内縁は、丸めた周を太さの半分だけ縮めた形。角の半径は `r − 太さの半分` で、
                // 太さの半分が半径以上なら直角になる (`max` が 0 に締める)。半径 0 は従来の箱
                float innerRadius = max(cornerRadius - halfWeight, 0.0);
                inner = mokume_roundedBoxField(q, hole, innerRadius);
                // 内縁は角を丸めたときだけ曲がった部分を持つ。尖った穴の角は線形のまま
                if (coverageMode == kCoverageLinearExceptCorners) {
                    innerLinear = !(innerRadius > 0.0 && all(abs(q) > hole - innerRadius));
                }
            }
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
        // 断片は、どの楕円も輪郭の位置で解き直す — 帯に丸ごと入る画素で、塗りだけの形の上に
        // 輪郭だけの形を重ねたのと同じ絵を出す約束 (下の割り戻しの説明) があり、近似のままだと
        // 輪郭の内縁に 1 次の近似の誤差 (半径 29 の円で被覆率 0.01 ほど) が残って、加算で表示の
        // 1 段を越えた ([#1643](https://github.com/mokume-metal/mokume/issues/1643))
        if (kFormHasFill) {
            fill = mokume_ellipseField(p, form.size.xy);
            // 1 画素より細い楕円の塗りは、`rect` の細い塗りと同じ境目で、両縁を見る積で
            // 数える (`mokume_thinEllipseCoverage`)。**距離場は細くても解く** — 輪郭の側が
            // それを読む (下の `mokume_shifted`・`mokume_shiftedBySlope`。塗りと輪郭を先に重ねる断片だけ)
            if (kFormHasThinFill
                && any(2.0 * form.size.xy * (1.0 + 2.0 * kFormSnap) < reachPerPixel)) {
                isThinFill = true;
                thinFillCoverage = mokume_thinEllipseCoverage(
                    p, form.size.xy, unitsPerPixel, in.inverseRows);
            }
        }
        if (kFormHasStroke) {
            FormField ring;
            if (kFormHasThinFill && in.ringFromFill == 3) {
                // 近似の距離場では内縁・外縁がずれすぎる細長い楕円 (`mokume_needsExactRing`)。
                // **輪郭の位置で真の距離を解く** — 塗りの距離場からはずらせない。列に含む形が
                // あるときだけ枝を残す (`kFormHasThinFill`)
                ring = mokume_ellipseExactField(q, form.size.xy);
            } else if (layered && kFormHasFill && in.ringFromFill == 2) {
                ring = mokume_shifted(fill, in.strokeShift);
            } else if (layered && kFormHasFill && in.ringFromFill == 1) {
                ring = mokume_shiftedBySlope(
                    fill, mokume_ellipseSlope(p, form.size.xy, fill), in.strokeShift);
            } else {
                ring = mokume_ellipseField(q, form.size.xy);
            }
            outer = mokume_grown(ring, halfWeight);
            // 帯の穴が潰れている・1 画素より細いときは、両縁を見る積で数える (`mokume_thinHole`・
            // `mokume_thinEllipseHoleCoverage`・[#2186](https://github.com/mokume-metal/mokume/issues/2186))。
            // 太さの半分が短半径以上なら穴は無い。穴が 1 画素以上ある細長い楕円の内縁の外れは
            // 輪郭を真の距離で解く枝が直す (`ringFromFill == 3`・
            // [#2742](https://github.com/mokume-metal/mokume/issues/2742))
            if (kFormHasThinFill && in.thinHole != 0) {
                float2 hole = mokume_ellipseHole(form.size.xy, halfWeight);
                isThinHole = true;
                thinHoleCoverage = all(hole > 0.0)
                    ? mokume_thinEllipseHoleCoverage(
                        q, form.size.xy, halfWeight, hole, unitsPerPixel, in.inverseRows)
                    : 0.0;
            } else {
                inner = mokume_grown(ring, -halfWeight);
                // 太さの半分が長い軸の端の曲率半径を越えると、穴の端は 2 本の平行曲線が交わる尖りに
                // なる。真の距離でも縁 1 本の式は、尖りの先の画素で穴を挟む 2 本の縁の片方しか見ず、
                // 穴の面積より大きく数える (内縁の被覆が穴の端の先に残り、`ellipse(0, 0, 100, 6)`・
                // 太さ 4 で帯に丸ごと入る画素に最大 35% の欠けが出た。#2186 の細い穴と同じ口)。両縁を見る
                // 積 (`mokume_thinEllipseHoleCoverage`) を上限に置く — 穴が広い所では積も縁 1 本とほぼ
                // 一致するので、上限は尖りの先でしか効かない
                if (kFormHasThinFill && in.ringFromFill == 3
                    && halfWeight * max(form.size.x, form.size.y)
                        > min(form.size.x, form.size.y) * min(form.size.x, form.size.y))
                {
                    float2 hole = mokume_ellipseHole(form.size.xy, halfWeight);
                    holeCap = all(hole > 0.0)
                        ? mokume_thinEllipseHoleCoverage(
                            q, form.size.xy, halfWeight, hole, unitsPerPixel, in.inverseRows)
                        : 0.0;
                    // 穴の端から長軸の向きに 6 画素以内の画素 (尖りの先) だけ、標本で数え直す
                    bool alongX = form.size.x >= form.size.y;
                    sampleCuspHole = (alongX ? abs(q.x) - hole.x : abs(q.y) - hole.y)
                        > -6.0 * (alongX ? unitsPerPixel.x : unitsPerPixel.y);
                }
            }
        }
    } else if (kind == kFormArc) {
        // 扇形は 1 次の近似でずらせない (`mokume_shifted` の説明)。塗りと輪郭で式を別々に解く。
        // 閉じ方 (`kArc*`・#2428) が、塗りの形 (扇か弦で結んだ形) と輪郭の形 (扇の周・弦で結んだ形の周・開いた弧の帯)
        // を決める。距離場は同じ式で、辺が 2 本の半径か 1 本の弦かだけが違う
        uint closure = uint(form.size.w);
        bool chordFill = mokume_arcFillsChord(closure);
        if (kFormHasFill) {
            fill = mokume_arcRegionField(
                p, form.size.xy, in.sectorDirections, form.offset.w, false, chordFill, in.chordLine);
        }
        if (kFormHasStroke) {
            // 近似の距離場がずれすぎる細長い楕円の扇は、輪郭の楕円の弧を真の距離で解く
            // (`mokume_needsExactRing`・#2747)。列に含む形があるときだけ枝を残す (`kFormHasThinFill`)
            bool exactRing = kFormHasThinFill && in.ringFromFill == 3;
            if (mokume_arcStrokesOpen(closure)) {
                // **開いた弧の帯。** 閉じた周が無いので内縁 (穴) は無い。外縁の距離場だけで足り、
                // 帯が 1 画素より細いときは両縁を見る被覆に替える (線の細い枝と同じ)
                bool thinBand = false;
                float thinBandCoverage = 0.0;
                outer = mokume_arcBandField(
                    q, form.size.xy, in.sectorDirections, in.arcMid, form.offset.w, exactRing,
                    halfWeight, form.meta.y, in.inverseRows, thinBand, thinBandCoverage);
                if (thinBand) {
                    isThinLine = true;
                    thinLineCoverage = thinBandCoverage;
                }
            } else {
                bool chordRing = closure == kArcChord;
                FormField ring = mokume_arcRegionField(
                    q, form.size.xy, in.sectorDirections, form.offset.w, exactRing, chordRing, in.chordLine);
                outer = mokume_grown(ring, halfWeight);
                inner = mokume_grown(ring, -halfWeight);
                // **帯の穴が潰れているか 1 画素より細い扇 (と弦で結んだ形) は、穴の面積を標本で数える**
                // (`mokume_sectorHoleCoverage`・[#2747](https://github.com/mokume-metal/mokume/issues/2747))。
                // 判定は頂点関数が決める (`thinHole`・`mokume_sectorDepthBound`・弦は `mokume_chordDepthBound`)。
                // それより太い穴は縁 1 本の距離場のまま (絵は 1 ビットも変わらない)
                if (kFormHasThinFill && in.thinHole != 0) {
                    bool sampled = in.thinHole == 1u;
                    if (!sampled) {
                        // 尖りの先 (尖りまでの距離 t で縁 1 本の被覆の余りが 0.5 − t · sin(θ/2) になる範囲) だけ。
                        // 扇の尖りは中心、弦で結んだ形の尖りは弧の両端の 2 つの角
                        float reachLimit = max(unitsPerPixel.x, unitsPerPixel.y);
                        if (chordRing) {
                            float4 apex1 = mokume_chordApex(form.size.xy, in.sectorDirections, halfWeight, 0u);
                            float4 apex2 = mokume_chordApex(form.size.xy, in.sectorDirections, halfWeight, 1u);
                            sampled = (apex1.w > 0.0
                                    && length(q - apex1.xy) < (2.0 / apex1.z + 2.0) * reachLimit)
                                || (apex2.w > 0.0
                                    && length(q - apex2.xy) < (2.0 / apex2.z + 2.0) * reachLimit);
                        } else {
                            float4 apex = mokume_sectorApex(form.size.xy, in.sectorDirections, form.offset.w, halfWeight);
                            sampled = length(q - apex.xy) < (2.0 / apex.z + 2.0) * reachLimit;
                        }
                    }
                    if (sampled) {
                        isThinHole = true;
                        thinHoleCoverage = mokume_sectorHoleCoverage(
                            q, form.size.xy, in.sectorDirections, form.offset.w, halfWeight,
                            chordRing
                                ? mokume_chordDepthBound(form.size.xy, form.offset.w)
                                : mokume_sectorDepthBound(form.size.xy, form.offset.w),
                            in.inverseRows, in.ringFromFill == 3, chordRing, in.chordLine);
                    }
                }
            }
        }
    } else if (kFormHasStroke) {
        // 線。塗りは持たず、線そのものの距離場を輪郭の外縁として使う
        float halfLength = form.size.x;
        // 描く画素 1 つが形自身の座標でいくらか (`unitsPerPixel`) は、x が長さの向き、
        // y が太さの向きになる
        if (kFormHasThinFill && 2.0 * halfWeight * (1.0 + 2.0 * kFormSnap) < reachPerPixel.y) {
            // **画面で 1 画素より細い線と点は、両縁を見る 1 次元の被覆の積で数える。**
            // 距離場は縁 1 本しか持たないので、帯の両縁が同じ画素に入ると、向こう側の縁の
            // 欠けを引けない — 線は画素の中心に乗る約束 (ADR-0039 決定 2) なので、整数の
            // 座標では帯の中心が画素の中心に来て、太さ 0.1 の線がその 1 画素を 0.55 で
            // 塗っていた (半端な座標の 5.9 倍・#1451)。
            //
            // 画素と帯の重なりを取る (箱フィルタ)。濃さは置く位置によらず太さに比例し、点は
            // 面積 (太さの 2 乗) に比例する。丸い端はここでは出っ張る端と同じ四角に数える —
            // 違いは画素 1 つの中に収まり、太さ 1 の丸い点 (下の枝で和 1.0〜1.17) とも続く。
            // 線の軸が画素の軸に沿うときは、太さの向きと長さの向きで重なる長さを取って掛け
            // 合わせる。**回した線は、画素の軸に沿った正方形を帯の縁で切って面積を出す**
            // (`mokume_boxCoverage`・#2226。長さの積では 45° の線が置く位置により 0.82〜1.12
            // 倍に振れた)。
            //
            // **1/256 の遊び (`mokume_formCoverage`) は掛けない。** 遊びは縁が画素の境目に
            // 乗るときの揺れを消すためのもので、両縁に掛けると細い帯ほど効きが大きくなる
            // (太さ 0.1 の帯を画素の境目に置くと 7%・太さ 0.05 で 15% 足りなくなる)。
            //
            // **境目は 1 画素ちょうどではなく 256/258 画素に置く。** 遊びを込めると、それより
            // 太い帯では向こう側の縁が画素の被覆に入らない (輪郭の差と積が一致するのと同じ
            // 境目・下の説明) ので、縁 1 本の距離場のままで両縁を見たのと 1 ビットも違わない。
            // 1 画素ちょうどに置くと、既定の太さ 1 で引いた線が、行の丸め (1e-7 ほど) で境目の両側へ
            // 散って絵が動く。境目を測るのは、描く画素の法線向きの幅 (`reachPerPixel`・線は直線の縁なので
            // 45° で √2。画素の正方形を線の太さの向きへ射影した幅で、帯の両縁が 1 つの画素に入るかを決める
            // 量。丸い点 (長さ 0 の丸い端) は円なので行ノルム・#2991)。
            // 太さが 256/258 画素以上の軸に沿う線はこの枝を通らないので、絵は 1 ビットも変わらない
            float reach = halfLength + (form.meta.y == kFormCapSquare ? 0.0 : halfWeight);
            isThinLine = true;
            // **丸い端はカプセルとして数える** (四角の端は箱のまま・`mokume_capsuleCoverage`)。端を箱で数えると、
            // 回した太さ 1〜1.41 の線 (法線向きの幅でこの枝に入る) の端が、1 つにつき約 0.107 · w² 多く出る
            thinLineCoverage = form.meta.y == kFormCapRound
                ? mokume_capsuleCoverage(q, halfLength, halfWeight, unitsPerPixel, in.inverseRows)
                : mokume_boxCoverage(q, float2(reach, halfWeight), unitsPerPixel, in.inverseRows);
        } else if (form.meta.y == kFormCapRound) {
            // カプセル: 線分からの距離 − 太さの半分
            float2 away = float2(q.x < 0.0 ? min(q.x + halfLength, 0.0) : max(q.x - halfLength, 0.0), q.y);
            outer = mokume_field(
                length(away) - halfWeight, mokume_direction(away, float2(0.0, 1.0)));
            // 回した線の辺は面積、丸い端の領域 (端の円弧・長さ 0 の点は全体) は線形の渡しのまま
            // (`point()`・丸い端の例外。回転で線形と面積が切り替わると、画素の値が飛ぶ)
            if (coverageMode == kCoverageLinearExceptCaps) {
                outerLinear = halfLength == 0.0 || abs(q.x) > halfLength;
            }
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
    paint.overlap = 0.0;
    // **線と点は塗りを持たない。** 旗で列が切れるので塗りのある列には混ざらないが、
    // 種別は列の中で混ざるので、ここで名指しして外す
    if (kFormHasFill && kind != kFormLine) {
        // 1 画素より細い塗りだけが別に数えた値を使う (`rect` の塗りの説明)。細い塗りを
        // 含まない列では `isThinFill` が常に偽なので、選ぶ式も原稿から消える
        paint.fillCoverage =
            isThinFill ? thinFillCoverage : mokume_formCoverage(fill, in.inverseRows, fillLinear);
    }
    if (kFormHasStroke) {
        float outerCoverage = mokume_formCoverage(outer, in.inverseRows, outerLinear);
        float innerEdge = mokume_formCoverage(inner, in.inverseRows, innerLinear);
        float innerCoverage = isThinHole ? thinHoleCoverage : min(innerEdge, holeCap);
        // 尖りの先では縁 1 本の値も上限の積 (長方形で数える) も穴を過大に数える (`ellipse(0, 0, 40, 10)`・
        // 太さ 6 で部分被覆が最大 0.22 外れた)。穴の端に近い画素だけ、穴の面積を標本で数える
        if (sampleCuspHole) {
            innerCoverage = mokume_ellipseHoleSampled(q, form.size.xy, halfWeight, in.inverseRows);
        }
        // **帯の被覆は、外縁の被覆 − 内縁の被覆。** 縁は画素の幅では平行とみなせるので、
        // 帯 = (外縁の内) − (内縁の内) で、画素の中の面積も引き算になる。2 つを掛け合わせる
        // 式 (外縁の内 × 内縁の外) は 2 つが画素の中で無関係に散らばっているとみなすので、
        // 両縁が同じ画素に入る 1 画素より細い帯では内縁の欠けを引き切れず、太さ 0.1 の縁の
        // 和が置く位置で 0.09〜0.30 に揺れていた (#1451)。
        //
        // 1 画素以上の帯では、内縁が画素に掛かるときは外縁が画素を覆い切っている (外縁の
        // 被覆がちょうど 1) ので、差と積は 1 ビットも違わない — 遊び (1/256) を込めて、画面の
        // 太さ 256/258 ≈ 0.9923 画素以上で成り立つ。線は内縁を持たない (被覆 0) ので外縁の
        // 被覆がそのまま残り、1 画素より細い線と点だけが別に数えた値を使う。内縁の被覆は、
        // 帯の穴が 1 画素より細いか潰れていれば両縁を見る積で数えた値を使う (`mokume_thinHole`)
        paint.strokeCoverage =
            isThinLine ? thinLineCoverage : max(0.0, outerCoverage - innerCoverage);
        if (kFormHasFill && kind != kFormLine) {
            // **塗りと輪郭の継ぎ目で下地を漏らさない。** 2 つの被覆率をそのまま重ねると、
            // 画素の中で「塗り」と「輪郭の帯」が互いに無関係に散らばっているとみなすことに
            // なり、2 つが接する画素 (塗りの縁が帯の内縁と揃う側) で下地が透ける — 輪郭を
            // 画面で半画素寄せる約束 (ADR-0039 決定 2) では、塗りと帯の中心が半画素違うので
            // 片側に必ず現れる (重ねる混ぜ方の太さ 1 で最悪 25%・太さ 2 で 12% 暗くなった)。
            //
            // そこで、画素の中で塗りと帯が**重なる面積** `o` を見積もる。縁が画素の幅では
            // 平行とみなせるので、平行な半平面どうしの共通部分の被覆率は小さいほうになる:
            // 塗り ∩ 帯 = (塗り ∩ 外縁) − (塗り ∩ 内縁)。これで画素を塗りだけ `f − o`・
            // 重なり `o`・帯だけ `s − o`・どちらでもない所の 4 つの面積に分け、それぞれを
            // 混ぜた色を面積で足す — 塗りと輪郭を両方持つ形の 1 画素の約束である
            // ([#1867](https://github.com/mokume-metal/mokume/issues/1867) 決定 1・ADR-0039
            // 決定 5)。塗りだけ・輪郭だけの列は旗が外すので、絵は 1 ビットも変わらない。
            //
            // 1 画素より細い塗り (両縁を見る積で、半平面ではない) でも、この見積もりのままで
            // 塗り ∪ 帯に丸ごと入る画素は漏れない。細い塗りに輪郭を付けた形の継ぎ目の漏れは、
            // 帯の穴を縁 1 本で数えていた内縁の口 (`mokume_thinHole`) が全部で、それを直した後に
            // 残る漏れは 0 だった (CPU の写しで、幅 0.2〜0.9 の `rect` と楕円・太さ 0.5〜3 を
            // 置き方 30 通りずつ・#2186)
            paint.overlap = max(
                0.0,
                min(paint.fillCoverage, outerCoverage) - min(paint.fillCoverage, innerCoverage));
            // 1 画素より細い帯 (開いた弧の帯・#2428) の重なりは、縁 1 本の外縁の被覆ではなく、両縁を見て数えた
            // 帯の被覆を越えない
            if (isThinLine) { paint.overlap = min(paint.overlap, paint.strokeCoverage); }
        }
        if (layered && kFormHasFill && kind != kFormLine) {
            // **塗りと輪郭を先に重ねる断片は、4 つの面積の和を塗りの被覆率の割り戻しで解く**
            // (`layered`)。重ねる (over) で解くと重なりには「輪郭 over 塗り」が入るので、
            // 塗りが見える重みは「帯の外の塗りは全部、帯の下の塗りは輪郭が透ける分だけ」
            // (`f − α·o`) になる。それを重ねる式 (輪郭 over 塗り) で割り戻したものを塗りの
            // 被覆率とすると、置く色は `S·s + F·(f − α·o)` で、4 つの面積をそれぞれ over で
            // 混ぜて足した色と項ごとに一致する。
            //
            // **割り戻すのは、塗りと輪郭を先に重ねる断片だけである。** 割り戻しは「輪郭を
            // 塗りの上に重ねる (over)」前提の式で、下地を読む断片 (`mokume_formFragment`) へ
            // 持ち込むと、不透明な輪郭の帯の内側半分で分母 (帯の透ける割合) が 0 になって
            // 塗りが消え、加算で塗りが足されなかった
            // ([#1643](https://github.com/mokume-metal/mokume/issues/1643))。下地を読む断片は
            // 割り戻す前の被覆率と `o` を受け取り、4 つの面積をそれぞれ下地と混ぜて足す。
            //
            // **置き換える列は、帯の下の塗りを少しも見せない** (`replacing`)。置き換えで
            // 解くと重なりには後に置いた輪郭だけが入るので、塗りが見える重みは `f − o` で、
            // 置く色は `S·s + F·(f − o)` になる。三角形の経路 (塗りの三角形の上に輪郭の
            // 三角形を置き換える) と、塗りだけ → 輪郭だけの順に分けて描いた絵が帯に置く色
            // と同じである。かつては置き換える列も重ねる重みで割り戻していたので、半透明の
            // 輪郭の帯の内側半分に塗りが透け、透明な地では α が輪郭の不透明度を越えて
            // 1.0 まで埋まった ([#1819](https://github.com/mokume-metal/mokume/issues/1819))。
            // 不透明な輪郭では 2 つの重みが同じになり、絵は 1 ビットも変わらない
            float strokeAlpha = form.stroke.a;
            float visible = paint.fillCoverage - paint.overlap * (replacing ? 1.0 : strokeAlpha);
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
///
/// **塗りと輪郭を両方持つ形の 1 画素は、4 つの面積に分けて混ぜる** ([#1818]・[#1867] 決定 1)。
/// 塗りだけ `f − o`・重なり `o`・帯だけ `s − o`・どちらでもない `1 − (f + s − o)` の
/// それぞれを被覆 1 で下地と混ぜ (重なりは塗りを混ぜた上に輪郭を混ぜる・どちらでもない所は
/// 下地のまま)、面積で足す。被覆率を掛けた塗りと輪郭を順に混ぜると、線形でない混ぜ方
/// (`.lightest` / `.screen` / `.darkest` / `.multiply` / `.difference` / `.exclusion`) では
/// 2 つが接する継ぎ目で下地が透けた (`.lightest` の白い円で、太さ 1 で最悪 24%・太さ 2 で
/// 12% 暗い)。重ねる列の割り戻し (`mokume_formPaint`) は、同じ読みを over で解いたものである。
///
/// **4 つに分けるのは、塗りの縁が帯に掛かる画素 (継ぎ目と、帯の下の塗りの縁) だけである。**
/// `mokume_composite` は上の色の被覆率について線形 (`mix(下地, 被覆 1 で混ぜた色, 被覆率)`)
/// なので、塗りか輪郭の片方しか掛からない画素と、塗りに丸ごと覆われた画素 (重なりが帯と
/// 同じになる) では、4 つの面積の和は被覆率を掛けて塗り → 輪郭の順に混ぜた式と同じになる。
/// そこは順に混ぜる式で出す — 塗りだけ・輪郭だけの形と、丸ごと覆われた画素の絵は 1 ビットも
/// 変わらない。分ける画素では `mokume_composite` を最大 3 回呼ぶ (どちらでもない面積は下地の
/// まま・重なりは塗りを混ぜた結果の上に輪郭を混ぜる)。
///
/// **呼ぶ口は、塗り → 輪郭の順に混ぜる式と分ける画素で共有し、片方しか掛からない画素は先に
/// 1 回で返す。** 分ける画素と分けない画素が同じ SIMD の組に混ざると、別々の口は組の中で順に
/// 走る。口を別にした形 (分ける画素だけの枝に 3 つ) は、直す前と比べた GPU 時間が、寸法違いの
/// 小さな円 4000 個 (塗り + 輪郭・太さ 1) で +32%・直径 700 の円 200 個で +3% だった。口を
/// 共有すると前者は +20% に下がったが、片方しか掛からない画素 (大きな形の中はほとんどこれ)
/// まで共有の口へ流すと後者が +10% に上がった。先に 1 回で返すと +27% と +1% になる — 面を
/// 覆う形の費用を小さく保つほうを取った (どれも release・1920×1080・[#1818])。
///
/// [#1818]: https://github.com/mokume-metal/mokume/issues/1818
/// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
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
    float f = paint.fillCoverage;
    float s = paint.strokeCoverage;
    // 片方しか掛からない画素。被覆 0 の側は掛けない (乗算を戻して掛け直す往復で最下位ビットが
    // 動くのを避ける)。塗りだけ・輪郭だけの列はいつもここで返る
    if (f <= 0.0 || s <= 0.0) {
        return mokume_composite(f > 0.0 ? paint.fill : paint.stroke, destination, mode);
    }
    // 両方掛かる画素。**塗りの上に輪郭**の順で下地と混ぜる — 塗りの三角形の上に輪郭の三角形を
    // 置いていたときと同じ順序。塗りに丸ごと覆われた画素は被覆率を掛けた色のまま 2 回で済み、
    // 塗りの縁が掛かる画素 (`split`) だけ、被覆 1 の色で 4 つの面積に分ける
    float o = paint.overlap;
    bool split = f < 1.0;
    float4 fillColor = paint.fill;
    float4 strokeColor = paint.stroke;
    if (split) {
        FormInstance form = instances[in.instance];
        fillColor = form.fill;
        strokeColor = form.stroke;
    }
    float4 filled = mokume_composite(fillColor, destination, mode);
    float4 stroked = filled;
    if (!split || o > 0.0) { stroked = mokume_composite(strokeColor, filled, mode); }
    if (!split) { return stroked; }
    float4 result = destination * max(0.0, 1.0 - (f + s - o)) + filled * (f - o) + stroked * o;
    if (s > o) { result += mokume_composite(strokeColor, destination, mode) * (s - o); }
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
