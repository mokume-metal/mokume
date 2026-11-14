<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 形: 図形・曲線・頂点・PShape・loadShape

Processing 本体のリファレンスのうち、category が `shape`・`pshape` か、所属 (`classanchor`) が `PShape` の 64 件。2D と 3D の図形・属性・曲線・頂点の関数、保持された図形を作る `createShape()`・`loadShape()`・`shape()`・`shapeMode()`、`PShape` のクラスのページとメンバーである。表の形式・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。`PShape` と `loadShape()` の中身は、Processing 4.5.7 のタグ `processing-1435-4.5.7` のソース (`PShapeSVG.java`・`PShapeJava2D.java`・`PShapeOpenGL.java`・`PShapeOBJ.java`・`PGraphics.java`) を読んで確かめた (実行はしていない)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 39 |
| 入れる | 0 |
| 作例待ち | 10 |
| 持たない | 15 |
| 計 | 64 |

この領域に共通すること:

- **保持された図形 `Shape` は、組み立て済みの頂点配列を持つ値型である** ([#788]・[ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md))。`createShape { }` か `loadShape(_:)` で作り、`shape(_:)` で描画する。子の一覧・頂点の読み書き・変換・表示フラグは持たず、色と線は組み立てたとき (読み込んだとき) に図形へ書き込まれる (描画する側の `fill` は効かない)。`PShape` の API のうち、この性質で「持たない」にしたものと、編集 API の形を決めるまで「作例待ち」にしたものは、下の `PShape` の節に分けた
- **読めないときは投げる。** `loadShape(_:)` は `null` を返さず `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける
- **平面の図形もカメラ (視点) と変換を通るが、奥行きは持たない (奥行き 0 の面に載り、奥行きを読みも書きもせず、重なりは呼び出し順で決まる)。引数に `z` を持つ形と立体は奥行きを持ち、奥行きで隠し合う** ([ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 1 の「改訂 (2026-11-07) — 平面の図形も視点と変換の奥行きを通る」・決定 2)。同じ名前で引数の数により変わることは、各 API の説明文に書く
- **曲線の分割数の設定は `curveDetail(_:)` の 1 つ**で、`bezierVertex`・`quadraticVertex`・`curveVertex`・`bezier()`・`curve()` のどれにも効く (Processing は `bezierDetail()` と `curveDetail()` が別の設定)

## 「入れる」の API をまとめた Feature

「入れる」の 3 件は、1 つの `Feature` で入れる (いまは 0 件。[#3710] で入れた 3 件は「同等」に移した)。欠けた形のうち、3 次元の曲線は別の 1 つで入れる (件数に入れない。[#3712] で入れた)。`loadShape()` の下の子の行にある SVG の勾配 (件数に入れない) は、既に起票済みの [#3031] を `Feature` として使う。

| Feature | API | 件数 |
| --- | --- | --- |
| [#3710] 通過点を結ぶ曲線を、頂点を使わず 一度の呼び出しで描く・求める API (入れた) | `curve()`・`curvePoint()`・`curveTangent()` | 3 |
| [#3712] 3 次元の曲線 (欠けた形・入れた) | `bezierVertex()`・`quadraticVertex()`・`curveVertex()` の `z` を持つ形と、引数が 12 個の `bezier()`・`curve()` | 0 |
| [#3031] SVG の勾配 (子の行・入れた) | `loadShape()` が読む `<linearGradient>`・`<radialGradient>` | 0 |

## 2D の図形

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `arc()` | `arc(_:_:_:_:_:_:)`・`arc(_:_:_:_:_:_:_:)` (閉じ方 `ArcMode`) | 同等 | 閉じ方を渡さない呼び出しは、塗りが扇形・輪郭が開いた弧 (Processing の既定)。`OPEN`・`CHORD`・`PIE` は `.open`・`.chord`・`.pie`。**`.open` の塗りは扇形ではなく、弧の両端を直線 (弦) で結んだ形**で、引数を渡さない既定と違う。楕円の角度は媒介変数表示の角度 (Processing と同じ) | [#2428]・PR [#3180] |
| `circle()`・`ellipse()`・`square()`・`triangle()`・`quad()` (5 件) | `circle(_:_:_:)`・`ellipse(_:_:_:_:)`・`square(_:_:_:)`・`triangle(_:_:_:_:_:_:)`・`quad(_:_:_:_:_:_:_:_:)` | 同等 | 引数の数と順序は Processing と同じ。`circle()` の 3 つ目は直径。引数の解釈は `ellipseMode()`・`rectMode()` の行 | — |
| `line()` | `line(_:_:_:_:)`・`line(_:_:_:_:_:_:)` | 同等 | 引数が 6 個の形は 立体の空間に引き、奥行きを持って奥行きで隠し合う (`beginShape(.lines)` と画素が一致する。4 個の形もカメラと変換を通るが、奥行きは持たない) | [#2462]・PR [#2869] |
| `point()` | `point(_:_:)`・`point(_:_:_:)` | 同等 | 引数が 3 個の形は 立体の空間に描く (`beginShape(.points)` と画素が一致する) | [#2462]・PR [#2869] |
| `rect()` | `rect(_:_:_:_:)`・`rect(_:_:_:_:_:)` | 同等 | 5 番目の引数は 4 つの角を同じ半径で丸める (短い辺の半分を上限にする。Processing と同じ)。角は円弧で描き、Processing の二次ベジェ曲線とは角の中ほどが半径の 4% ほど違う。無い形: 4 つの角を別々に丸める、引数が 8 個の形 (`tl, tr, br, bl`)。[#2428] が「作例が来てから」と決めた | [#2428]・[#2757]・PR [#2821] |

## 3D の図形

3 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `box()` | `box(_:)`・`box(_:_:_:)` | 同等 | 引数 1 つは立方体の一辺、引数 3 つは幅・高さ・奥行き。中心は原点で、大きさの単位は画素 | [#289] |
| `sphere()` | `sphere(_:detail:)` | 同等 | 半径と、一周の分割数 (`detail:`)。Processing の分割数の設定は次の行 | [#289] |
| `sphereDetail()` | `sphere(_:detail:)` の `detail:` | 持たない | Processing のように状態として設定せず、呼び出しごとに引数で渡す。立体の種類をまたいで「一周の分割数」を 1 つの引数に統一した ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の「立体の `detail:`」)。無い形: 経度方向と緯度方向を別々に渡す `sphereDetail(ures, vres)`。ADR が「作例が来てから決める」とした | [#289] |

## 属性

5 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `ellipseMode()`・`rectMode()` (2 件) | `ellipseMode(_:)`・`rectMode(_:)` (`ShapeMode`) | 同等 | `CORNER`・`CORNERS`・`CENTER`・`RADIUS` は `.corner`・`.corners`・`.center`・`.radius`。既定は矩形が角を基準に、楕円が中心を基準にする (Processing と同じ) | — |
| `strokeCap()`・`strokeJoin()`・`strokeWeight()` (3 件) | `strokeCap(_:)` (`.round`・`.square`・`.project`)・`strokeJoin(_:)` (`.miter`・`.bevel`・`.round`)・`strokeWeight(_:)` | 同等 | 定数を列挙型の値にした。既定は線端が丸く、接合部が尖る (Processing と同じ) | — |

## 曲線

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `bezier()` | `bezier(_:_:_:_:_:_:_:_:)`・`bezier(_:_:_:_:_:_:_:_:_:_:_:_:)` | 同等 | `beginShape()`・`vertex`・`bezierVertex`・`endShape()` を順に呼んだのと同じ絵。塗りが有効なら、始点と終点を結ばない開いた図形のまま塗る。`z` を持つ、引数が 12 個の形は `vertex(x, y, z)`・引数が 9 個の `bezierVertex` を並べたのと同じ絵で、奥行きを持って奥行きで隠し合う。引数ラベル付きの形 `bezier(from:control1:control2:to:)` は `Vector2` と `Vector3` の両方を受ける | [#2430]・PR [#3043]・[#3712] |
| `bezierDetail()` | `curveDetail(_:)` | 同等 | 分割数の設定は 1 つで、ベジェ・2 次・通過点を結ぶ曲線のどれにも効く (Processing は `bezierDetail()` と `curveDetail()` が別の設定)。ベジェだけを粗くするなど、別々に設定する方法は無い。1…1024 の外は範囲内に収め、1 度だけ警告する。名前だけ違う API は足さない | [#2430] |
| `bezierPoint()`・`bezierTangent()` (2 件) | `bezierPoint(_:_:_:_:_:)`・`bezierTangent(_:_:_:_:_:)` | 同等 | 値だけを扱う関数 (描画はしない)。`x` と `y` を別々に求め、`atan2` で角度にする。`t` が 0…1 の外でも範囲内に収めない | [#2430]・PR [#3043] |
| `curve()`・`curvePoint()`・`curveTangent()` (3 件) | `curve(_:_:_:_:_:_:_:_:)`・`curve(_:_:_:_:_:_:_:_:_:_:_:_:)`・`curve(from:control1:control2:to:)`・`curvePoint(_:_:_:_:_:)`・`curveTangent(_:_:_:_:_:)` | 同等 | `curve()` は `beginShape()`・`curveVertex` を 4 回・`endShape()` を順に呼んだのと同じ絵で、描くのは 2 つ目から 3 つ目の点までの 1 区間 (`curveDetail`・`curveTightness` も同様に効く)。引数ラベル付きの形は `bezier(from:control1:control2:to:)` に揃え、`control1` が始点の手前・`control2` が終点の先の点。`curvePoint()`・`curveTangent()` は Processing と同じく `curveTightness()` の設定を読む (`PGraphics.java` の `curveInit()` が張力から基底行列を作る) ので、値だけの `bezierPoint()` と違ってスケッチと描画先 (`Canvas`) のメソッドで、引数ラベル付きの形は持たない (`bezierPoint()` と同じ)。`x` と `y` を別々に求め、`atan2` で角度にする。`z` を持つ、引数が 12 個の `curve()` は、同じ 4 点を `curveVertex(x, y, z)` で 4 回指定したのと同じ絵で、引数ラベル付きの形は `Vector3` も受ける | [#2430]・[#3710]・[#3712] |
| `curveDetail()` | `curveDetail(_:)` | 同等 | 1 区間あたりの分割数。既定は 20 (Processing と同じ)。`createShape { }` の中で変えても、抜けると戻る | [#2430] |
| `curveTightness()` | `curveTightness(_:)` | 同等 | 0 が既定で、1 にすると点と点が直線で結ばれる (Processing と同じ) | [#2430] |

## 頂点

8 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `beginShape()`・`endShape()` (2 件) | `beginShape(_:)` (`VertexKind`)・`endShape(_:)` (`ShapeEnd`) | 同等 | 頂点の並べ方 (図形の種類) は `.polygon` (既定)・`.points`・`.lines`・`.triangles`・`.quads`・`.triangleStrip`・`.triangleFan`。`endShape(CLOSE)` は `endShape(.close)`。無い形: `QUAD_STRIP`。[#902] が実際に必要になるまで待つと決めて閉じ、足すなら新しい `Feature` を立てる | [#882]・[#1551]・[#902] |
| `beginContour()`・`endContour()` (2 件) | `beginContour()`・`endContour()` | 同等 | 図形の中の穴。閉じてからもう一度開けば、穴はいくつでも空けられる。頂点が 3 つに満たない穴は破棄する | — |
| `vertex()` | `vertex(_:_:)`・`vertex(_:_:_:)`・`vertex(_:_:_:_:)`・`vertex(_:_:_:_:_:)`・`vertex(_: Vector2)`・`vertex(_: Vector3)` | 同等 | リファレンスの 5 つの引数の形 (`x, y`・`x, y, z`・`v`・`x, y, u, v`・`x, y, z, u, v`) がすべてある。`PVector` は `Vector2`・`Vector3` | — |
| `bezierVertex()`・`quadraticVertex()` (2 件) | `bezierVertex(_:_:_:_:_:_:)`・`bezierVertex(_:_:_:_:_:_:_:_:_:)`・`quadraticVertex(_:_:_:_:)`・`quadraticVertex(_:_:_:_:_:_:)` | 同等 | 直前の頂点から接続する。直前に頂点が無ければ何もしない。`z` を持つ、引数が 9 個・6 個の形は、分割した点を `vertex(x, y, z)` と同じ奥行きを持つ点として置く (直前の頂点が平面の点なら `z` を 0 として読む)。引数が 6 個・4 個の平面の形は、`z` を持つ形に `z` = 0 を渡したのと同じ絵になる (`vertex(x, y)` が `vertex(x, y, 0)` と同じなのと同じ)。直前の頂点が奥行きを持てば、曲線はその点から `z` = 0 の制御点・終点へ向かう ([#3712] で変えた。前は分割点がどれも直前の頂点の `z` のままだった)。引数ラベル付きの形は `Vector2` と `Vector3` の両方を受ける | [#2462]・[#3712] |
| `curveVertex()` | `curveVertex(_:_:)`・`curveVertex(_:_:_:)` | 同等 | 頂点が 4 つ揃って 1 区間が描ける (最初と最後の頂点は曲がり具合を決める制御点)。端まで描くには端の頂点を 2 度指定する (Processing と同じ)。`z` を持つ形と平面の形は混ぜてよく、平面の形は `z` を持つ形に `z` = 0 を渡したのと同じ絵になる (`vertex(x, y)` が `vertex(x, y, 0)` と同じなのと同じ)。奥行きを持つ点の後でも通過点は `z` = 0 である ([#3712] で変えた。前は分割点が直前の頂点の `z` のままだった) | [#2462]・[#3712] |

## 保持した形

4 件。`loadShape()` の下の 2 行は子の行で、件数に入れない。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `createShape()` | `createShape(_:)` | 同等 | クロージャの中で `beginShape()` や図形の API を呼んで組み、`setup()` で 1 度だけ作る。**色・線の太さ・シェーダは図形に書き込まれ、描画するときに外側で指定した `fill` は効かない。** 無い形: 空の図形を返して後から `beginShape()` を呼ぶ形と、種類を渡す形 (`createShape(RECT, a, b, c, d)` ほか。`createShape { rect(a, b, c, d) }` と書く) | [#788] |
| `loadShape()` | `loadShape(_:)`・`requestShape(_:)` | 同等 | SVG を読み、`createShape { }` と同じ `Shape` にする。読めないときは投げる (Processing は `null`)。無い形: URL から読むこと・OBJ を `Shape` として読むこと (OBJ は `loadModel(_:normalize:)` が `Model` として読む) | [#2019]・PR [#2192] |
| `shape()` | `shape(_:_:_:)`・`shape(_:at:)` | 同等 | 位置を省けば、平行移動した原点に描く。大きさは `scale(_:_:)` か `Placement` の `scale` で変える。無い形: 幅と高さを渡す `shape(shape, a, b, c, d)` (`shapeMode()` とセットで、下の行) | — |
| `shapeMode()` | — | 作例待ち | `shape()` の 3・4 番目の数の読み方 (`CORNER`・`CORNERS`・`CENTER`) を変える状態で、幅と高さを渡す形とセットになる。選択が分かれる点は、**図形自身の大きさを何と定義するか**。Processing の `PShape.getWidth()` は、既定のレンダラー (JAVA2D) では描く領域の大きさ (SVG なら `width` か `viewBox`。ソースに「形の境界とは限らない」とある) で、P2D・P3D では頂点の範囲と、レンダラーで違う。mokume の `Shape.bounds` は描画内容の外接矩形 (線の太さを含まず、平面の部分が無ければ `nil`) で、SVG の `viewBox` の大きさは持たない。中心に描くにも、どの範囲の中心かで選択が分かれる。いまは `bounds` の `center` を引いて描く (`shape(read, -box.center.x, -box.center.y)`) | [#2426]・PR [#3098] |

### `loadShape()` の下の子の行 (件数に入れない)

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| └ `loadShape()` が読む SVG の `<linearGradient>`・`<radialGradient>` | `loadShape(_:)` (`fill="url(#…)"` の勾配で塗る。`stop` の色と不透明度・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform`・`gradientUnits` (既定の `objectBoundingBox` と `userSpaceOnUse`)・`href` (`xlink:href`) によるストップの継承を読む。`spreadMethod` の `reflect`・`repeat`・中心と違う焦点 (`fx`・`fy`・`fr`)・`href` で指した勾配の属性・11 個目からのストップは読み込まずに警告し、`pad` と中心の焦点で描く。線の勾配 (`stroke="url(#…)"`) は読み込まずに警告する) | 入れる | Processing 4.5.7 は読む。`PShapeSVG.java` が `stop` の色と不透明度・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform` を読み、塗るのは JAVA2D のレンダラーだけ (`PShapeJava2D.java` の `calcGradientPaint`・`styles()`。`PShapeOpenGL.java` に勾配を扱うコードは無い)。`spreadMethod`・`gradientUnits`・`fx`・`fy`・`href` による継承は読まない。mokume は Processing より広く、`gradientUnits` の既定 (`objectBoundingBox`。Illustrator・Figma・Inkscape の書き出しが座標を外接矩形の割合で書く) と `href` によるストップの継承 (Inkscape の書き方) まで読む (2026-11-10 の決定・[#3933])。塗るのは描画状態の勾配と同じ `Gradient` と `fill(_: Gradient)` の経路で、補間する色空間は線形 (SVG の既定 `color-interpolation: sRGB` より中間の色が明るい)。読めない書き方は読み飛ばして警告する。描画前に設定した勾配が読み込んだ SVG に効かないこと ([#3008] の仕様) は変わらない | [#3031]・[#3008]・PR [#3009] |
| └ `loadShape()` が読む OBJ の材質 (`mtllib`・`usemtl`・MTL の `Kd`・`Ka`・`Ks`・`Ns`・`d`)・拡散テクスチャ (`map_Kd`)・グループ名 (`g`) | — (`loadModel` は形状・法線・UV だけを読み、マテリアル・テクスチャ・オブジェクトの区切りは読み飛ばす) | 作例待ち | Processing 4.5.7 は読む (`PShapeOBJ.java`)。`Kd`・`Ka`・`Ks`・`Ns`・`d` を面ごとの色と光沢に、`map_Kd` を拡散テクスチャに使う。**面ごとに子の図形を 1 つ作るが、`g` の名前は子に渡さず、読み返す API も無い** (`OBJFace.name` に記録するだけ)。グループ名から `getChild(名前)` では取得できず、番号の `getChild(index)` だけ取得できる。選択が分かれる点は、**マテリアルの表現を 1 つにする**こと。OBJ 専用のマテリアルの型を先に公開せず、[#2607] の glb と同じ表現に載せる。読み込んだマテリアルとスケッチが呼んだ `fill`・`texture` のどちらが勝つか、存在しない MTL・テクスチャの扱いも決まっていない。OBJ を `Shape` でなく `Model` として読む形 (上の `loadShape()` の行) も、そこで決める | [#3476]・[#2607] |

## PShape

26 件。クラスのページ 1 件と、メンバー 25 件 (`beginContour()`・`endContour()` と、category の無い `getChildCount()`・`setFill()`・`setStroke()` を含む)。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PShape` (クラス) | `Shape` | 同等 | 保持された図形の型。組み立て済みの頂点配列を持つ値型で、ツリーを作らず、グループにしても描画回数が増えない (`Shape.group(_:)`・`+`)。子の一覧・頂点の読み書き・変換・表示フラグ・色の差し替えは持たない (下の各行) | [#788]・[#2426] |
| `PShape.width`・`PShape.height` (2 件) | `Shape.bounds` の `width`・`height` | 同等 | 平面の部分の外接矩形を、図形自身の座標で返す。**描画内容の外接矩形で、線の太さを含まない。** Processing のリファレンスは「文書の大きさ」と書き、既定のレンダラー (JAVA2D) では SVG の `width` か `viewBox` の大きさなので、余白のある SVG では値が違う (P2D・P3D は頂点の範囲で、こちらに近い)。平面の部分が無い図形 (立体だけ・`Shape.empty`) は `nil` を返す | [#2426]・PR [#3098] |
| `PShape.beginShape()`・`endShape()`・`beginContour()`・`endContour()` (4 件) | `createShape { }` の中の `beginShape(_:)`・`endShape(_:)`・`beginContour()`・`endContour()` | 持たない | 図形に頂点を追加するメソッドは、図形の側に持たない。クロージャの中で、スケッチと同じ API で組み立てる。組み立てた後は書き換えない | [#788] |
| `PShape.addChild()` | `Shape.group(_:)`・`+` | 持たない | グループ化は図形の型の静的メソッドで、1 本の頂点配列に連結するだけ (ツリーを作らない)。挿入位置を指定する形 (`addChild(who, idx)`) は無い | — |
| `PShape.isVisible()`・`setVisible()` (2 件) | `if` で `shape(_:)` を呼ぶか決める | 持たない | 図形は表示フラグを持たない。描画するかどうかは `shape(_:)` を呼ぶかで決める (Swift の条件分岐) | — |
| `PShape.resetMatrix()`・`rotate()`・`rotateX()`・`rotateY()`・`rotateZ()`・`scale()`・`translate()` (7 件) | `translate`・`rotate`・`scale` と `push()`・`pop()`、`Placement` | 持たない | 頂点を書き換えず、描画時の変換が同じ働きをする。図形自身の座標を変えたいときは、`createShape { }` の中で変換を書く (中で書いた変換は図形の頂点へ反映される) | — |
| `PShape.getChild()` | — | 作例待ち | **[#2426] の決定 (2026-10-16) 「`id` で部分を取り出す API (`getChild`) は、要る作例が来るまで持たない」を転記したもの。** 表で「入れる」を選べば、ADR-0041 決定 3 の改訂により作例なしで進めることになり、この決定の選び直しになる。[#3471] (not planned) の閉じるコメントも、表で「入れる」と選ばれたら開き直さず、その種類の `Feature` を立てるとする。選択が分かれる点は、子を取得する編集用の API を `Shape` に足すか別の型にするか ([#3471] の B) と、名前を SVG の `id` から取るか。Processing の SVG は子の名前に `id` を使い、`getChild(名前)` はツリー全体を探す。OBJ の子には名前が無い (`loadShape()` の OBJ の行)。無い形: 番号の `getChild(index)` | [#2426]・[#3471] |
| `PShape.getVertexCount()`・`getVertex()`・`setVertex()` (3 件) | — (`Shape.vertexCount` は別の数) | 作例待ち | スケッチの作者が指定した頂点は、`Shape` に残らない。残るのは三角形に分割した頂点で、`Shape.vertexCount` はその数であり、距離関数で描く基本図形 (矩形・楕円・線・点) は 0 と数える。選択が分かれる点は、何を頂点と呼ぶか (指定した点を別に保持するか、`Path` の点か) と、書き換えを値型でどう表すか (`mutating` か、書き換えたコピーを返すか)。[#2426] の `getChild` と同じく、編集用の API の形が決まるまで待つ。いまは自分の配列に点を持ち、`createShape { }` で組み直す | [#2426]・[#3471] |
| `PShape.disableStyle()`・`enableStyle()` (2 件) | — (配置で色を掛ける `Placement.fill`) | 作例待ち | 図形の色と線の設定を無視して、いまの `fill()`・`stroke()` で描く。mokume は色を図形に書き込むと決めている ([#788]・[ADR-0045](../decisions/0045-game-direction.md))。[#3008] は「明示して有効にする API で、描画時に記録した塗りを破棄する」案 (B) を採らず、「作例が来たときに選ぶ」とした。[#2019] の完了報告も同じ。選択が分かれる点は、無視するのが色だけか、線の太さ・線端の形までか。いまは白で描いた図形に `Placement.fill` で色を掛ける (色だけ) | [#3008]・[#2019] |
| `PShape.getChildCount()` | — | 作例待ち | `getChild()` とセット。子を取得する編集用の API の形が決まるまで待つ | [#2426]・[#3471] |
| `PShape.setFill()`・`setStroke()` (2 件) | — (配置で色を掛ける `Placement.fill`) | 作例待ち | 組み立てた後に図形の色を差し替える API。`disableStyle()` と同じ選択肢 (色の差し替えを図形に持つか、配置で掛けるか) で、同じ決定に従う | [#3008] |

[#289]: https://github.com/mokume-metal/mokume/issues/289
[#788]: https://github.com/mokume-metal/mokume/issues/788
[#882]: https://github.com/mokume-metal/mokume/issues/882
[#902]: https://github.com/mokume-metal/mokume/issues/902
[#1551]: https://github.com/mokume-metal/mokume/issues/1551
[#2019]: https://github.com/mokume-metal/mokume/issues/2019
[#2192]: https://github.com/mokume-metal/mokume/pull/2192
[#2426]: https://github.com/mokume-metal/mokume/issues/2426
[#2428]: https://github.com/mokume-metal/mokume/issues/2428
[#2430]: https://github.com/mokume-metal/mokume/issues/2430
[#2462]: https://github.com/mokume-metal/mokume/issues/2462
[#2607]: https://github.com/mokume-metal/mokume/issues/2607
[#2757]: https://github.com/mokume-metal/mokume/issues/2757
[#2821]: https://github.com/mokume-metal/mokume/pull/2821
[#2869]: https://github.com/mokume-metal/mokume/pull/2869
[#3008]: https://github.com/mokume-metal/mokume/issues/3008
[#3009]: https://github.com/mokume-metal/mokume/pull/3009
[#3031]: https://github.com/mokume-metal/mokume/issues/3031
[#3043]: https://github.com/mokume-metal/mokume/pull/3043
[#3098]: https://github.com/mokume-metal/mokume/pull/3098
[#3133]: https://github.com/mokume-metal/mokume/issues/3133
[#3180]: https://github.com/mokume-metal/mokume/pull/3180
[#3471]: https://github.com/mokume-metal/mokume/issues/3471
[#3476]: https://github.com/mokume-metal/mokume/issues/3476
[#3710]: https://github.com/mokume-metal/mokume/issues/3710
[#3712]: https://github.com/mokume-metal/mokume/issues/3712
[#3933]: https://github.com/mokume-metal/mokume/issues/3933
