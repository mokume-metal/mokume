<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 形: 図形・曲線・頂点・PShape・loadShape

Processing の本体の参照のうち、category が `shape`・`pshape` か、所属 (`classanchor`) が `PShape` の 64 件。2D と 3D の図形・属性・曲線・頂点の関数、保持した形を作る `createShape()`・`loadShape()`・`shape()`・`shapeMode()`、`PShape` のクラスの頁とメンバーである。形・バージョン・数え直す式は [README](README.md) にある。照合したのは processing-website `f4acef8` (2026-10-29) と mokume の main `fe258089` (2026-11-02)。`PShape` と `loadShape()` の中身は、Processing 4.5.7 のタグ `processing-1435-4.5.7` のソース (`PShapeSVG.java`・`PShapeJava2D.java`・`PShapeOpenGL.java`・`PShapeOBJ.java`・`PGraphics.java`) を読んで確かめた (走らせてはいない)。

| 区分 | 件数 |
| --- | --- |
| 同等 | 39 |
| 入れる | 0 |
| 作例待ち | 10 |
| 持たない | 15 |
| 計 | 64 |

この領域に共通すること:

- **保持した形 `Shape` は、焼いた頂点の並びの値の型である** ([#788]・[ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md))。`createShape { }` か `loadShape(_:)` で作り、`shape(_:)` で置く。子の一覧・頂点の読み書き・変換・表示の旗は持たず、色と線は組んだとき (読んだとき) に形へ焼き付く (置く側の `fill` は効かない)。`PShape` の API のうち、この性質で「持たない」にしたものと、編集の表現を決めるまで「作例待ち」にしたものは、下の `PShape` の節に分けた
- **読めないときは投げる。** `loadShape(_:)` は `null` を返さず `DataFailure` を投げ、`setup() throws` の `try` か `try?` で受ける
- **平面の図形は視点を通らず、引数に `z` を持つ形と立体は奥行きと視点を通る** ([ADR-0021](../decisions/0021-solid-space-and-frame-assembly.md) 決定 2)。同じ名前で引数の数により変わることは、各 API の説明文に書く
- **曲線の刻みは `curveDetail(_:)` の 1 本** で、`bezierVertex`・`quadraticVertex`・`curveVertex`・`bezier()`・`curve()` のどれにも効く (Processing は `bezierDetail()` と `curveDetail()` が別の設定)

## 入れるの束

「入れる」の 3 件は、1 本の `Feature` で入れる (いまは 0 件。[#3710] で入れた 3 件は「同等」に移した)。欠けた形のうち、3 次元の曲線は別の 1 本で入れる (件数に入れない)。`loadShape()` の下の子の行にある SVG の勾配 (件数に入れない) は、既に開いている [#3031] を `Feature` として使う。

| 束 | 口 | 件数 |
| --- | --- | --- |
| [#3710] 通過点を結ぶ曲線の単発の API (入れた) | `curve()`・`curvePoint()`・`curveTangent()` | 3 |
| [#3712] 3 次元の曲線 (欠けた形) | `bezierVertex()`・`quadraticVertex()`・`curveVertex()` の `z` を持つ形と、12 の数の `bezier()` | 0 |
| [#3031] SVG の勾配 (子の行) | `loadShape()` が読む `<linearGradient>`・`<radialGradient>` | 0 |

## 2D の図形

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `arc()` | `arc(_:_:_:_:_:_:)`・`arc(_:_:_:_:_:_:_:)` (閉じ方 `ArcMode`) | 同等 | 閉じ方を渡さない形は、塗りが扇・輪郭が開いた弧 (Processing の既定)。`OPEN`・`CHORD`・`PIE` は `.open`・`.chord`・`.pie`。**`.open` の塗りは扇でなく弦で結んだ形**で、引数を渡さない既定と違う。楕円の角度は媒介変数の角 (Processing と同じ) | [#2428]・PR [#3180] |
| `circle()`・`ellipse()`・`square()`・`triangle()`・`quad()` (5 件) | `circle(_:_:_:)`・`ellipse(_:_:_:_:)`・`square(_:_:_:)`・`triangle(_:_:_:_:_:_:)`・`quad(_:_:_:_:_:_:_:_:)` | 同等 | 引数の数と順は Processing と同じ。`circle()` の 3 つ目は直径。読み方は `ellipseMode()`・`rectMode()` の行 | — |
| `line()` | `line(_:_:_:_:)`・`line(_:_:_:_:_:_:)` | 同等 | 6 つの数の形は立体の空間に引き、奥行きと視点を通る (`beginShape(.lines)` と画素が一致する) | [#2462]・PR [#2869] |
| `point()` | `point(_:_:)`・`point(_:_:_:)` | 同等 | 3 つの数の形は立体の空間に置く (`beginShape(.points)` と画素が一致する) | [#2462]・PR [#2869] |
| `rect()` | `rect(_:_:_:_:)`・`rect(_:_:_:_:_:)` | 同等 | 5 つ目は 4 つの角を同じ半径で丸める (短い辺の半分に締める。Processing と同じ)。角は円弧で描き、Processing の二次曲線とは角の中ほどが半径の 4% ほど違う。無い形: 4 つの角を別々に丸める 8 つの数の形 (`tl, tr, br, bl`)。[#2428] が「作例が来てから」と決めた | [#2428]・[#2757]・PR [#2821] |

## 3D の図形

3 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `box()` | `box(_:)`・`box(_:_:_:)` | 同等 | 1 つの数は立方体、3 つの数は幅・高さ・奥行き。中心は原点で、大きさは画素 | [#289] |
| `sphere()` | `sphere(_:detail:)` | 同等 | 半径と、一周をいくつに割るか (`detail:`)。Processing の分割数は次の行 | [#289] |
| `sphereDetail()` | `sphere(_:detail:)` の `detail:` | 持たない | 状態で決める手本と違い、形ごとに引数で渡す。形をまたいで「一周をいくつに割るか」の 1 本にそろえた ([ADR-0020](../decisions/0020-api-naming-and-surface.md) 決定 1 の「立体の `detail:`」)。無い形: 経度と緯度を別々に渡す `sphereDetail(ures, vres)`。ADR が「作例が来てから決める」とした | [#289] |

## 属性

5 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `ellipseMode()`・`rectMode()` (2 件) | `ellipseMode(_:)`・`rectMode(_:)` (`ShapeMode`) | 同等 | `CORNER`・`CORNERS`・`CENTER`・`RADIUS` は `.corner`・`.corners`・`.center`・`.radius`。既定は矩形が角から、楕円が中心から (Processing と同じ) | — |
| `strokeCap()`・`strokeJoin()`・`strokeWeight()` (3 件) | `strokeCap(_:)` (`.round`・`.square`・`.project`)・`strokeJoin(_:)` (`.miter`・`.bevel`・`.round`)・`strokeWeight(_:)` | 同等 | 定数を列挙型の値にした。既定は端が丸く、折れ目が尖る (Processing と同じ) | — |

## 曲線

9 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `bezier()` | `bezier(_:_:_:_:_:_:_:_:)` | 同等 | `beginShape()`・`vertex`・`bezierVertex`・`endShape()` を順に呼んだのと同じ絵。塗りが有効なら、始点と終点を結ばない開いた形のまま塗る。無い形: `z` を持つ 12 の数の形 ([#3712] で入れる) | [#2430]・PR [#3043]・[#3712] |
| `bezierDetail()` | `curveDetail(_:)` | 同等 | 刻みは 1 つで、ベジェ・2 次・通過点を結ぶ曲線のどれにも効く (Processing は `bezierDetail()` と `curveDetail()` が別の設定)。ベジェだけを粗くするなど、別々にする形は無い。1…1024 の外は端へ丸め、1 度だけ知らせる。名前だけ違う API は足さない | [#2430] |
| `bezierPoint()`・`bezierTangent()` (2 件) | `bezierPoint(_:_:_:_:_:)`・`bezierTangent(_:_:_:_:_:)` | 同等 | 値だけを扱う関数。`x` と `y` を別々に読み、`atan2` で向きにする。`t` は 0…1 の外も締めない | [#2430]・PR [#3043] |
| `curve()`・`curvePoint()`・`curveTangent()` (3 件) | `curve(_:_:_:_:_:_:_:_:)`・`curve(from:control1:control2:to:)`・`curvePoint(_:_:_:_:_:)`・`curveTangent(_:_:_:_:_:)` | 同等 | `curve()` は `beginShape()`・`curveVertex` を 4 回・`endShape()` を順に呼んだのと同じ絵で、引くのは 2 つ目から 3 つ目の点までの 1 区間 (`curveDetail`・`curveTightness` も同じに効く)。ラベル付きの形は `bezier(from:control1:control2:to:)` に揃え、`control1` が始点の手前・`control2` が終点の先の点。`curvePoint()`・`curveTangent()` は Processing と同じく `curveTightness()` の設定を読む (`PGraphics.java` の `curveInit()` が張りで基底の行列を作る) ので、値だけの `bezierPoint()` と違ってスケッチと描画先 (`Canvas`) のメソッドで、ラベル付きの形は持たない (`bezierPoint()` と同じ)。`x` と `y` を別々に読み、`atan2` で向きにする。無い形: `z` を持つ 12 の数の `curve()` ([#3712] で入れる) | [#2430]・[#3710]・[#3712] |
| `curveDetail()` | `curveDetail(_:)` | 同等 | 1 区間あたりの刻みの数。既定は 20 (Processing と同じ)。`createShape { }` の中で変えても、抜けると戻る | [#2430] |
| `curveTightness()` | `curveTightness(_:)` | 同等 | 0 が既定で、1 にすると点と点が直線で結ばれる (Processing と同じ) | [#2430] |

## 頂点

8 件。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `beginShape()`・`endShape()` (2 件) | `beginShape(_:)` (`VertexKind`)・`endShape(_:)` (`ShapeEnd`) | 同等 | 並べ方は `.polygon` (既定)・`.points`・`.lines`・`.triangles`・`.quads`・`.triangleStrip`・`.triangleFan`。`endShape(CLOSE)` は `endShape(.close)`。無い形: `QUAD_STRIP`。[#902] が実需が来るまで待つと閉じ、足すなら新しい `Feature` を立てる | [#882]・[#1551]・[#902] |
| `beginContour()`・`endContour()` (2 件) | `beginContour()`・`endContour()` | 同等 | 形の中の穴。閉じてからもう一度開けば、穴はいくつでも空けられる。頂点が 3 つに満たない穴は捨てる | — |
| `vertex()` | `vertex(_:_:)`・`vertex(_:_:_:)`・`vertex(_:_:_:_:)`・`vertex(_:_:_:_:_:)`・`vertex(_: Vector2)`・`vertex(_: Vector3)` | 同等 | 参照の 5 つの形 (`x, y`・`x, y, z`・`v`・`x, y, u, v`・`x, y, z, u, v`) がすべてある。`PVector` は `Vector2`・`Vector3` | — |
| `bezierVertex()`・`quadraticVertex()` (2 件) | `bezierVertex(_:_:_:_:_:_:)`・`quadraticVertex(_:_:_:_:)` | 同等 | いまの点から繋ぐ。手前に点が無ければ何もしない。無い形: `z` を持つ 9 つ・6 つの数の形 ([#3712] で入れる) | [#2462]・[#3712] |
| `curveVertex()` | `curveVertex(_:_:)` | 同等 | 4 つ揃って 1 区間が引ける (最初と最後の点は曲がり方を決めるだけ)。端まで引くには端の点を 2 度置く (Processing と同じ)。無い形: `z` を持つ形 ([#3712] で入れる) | [#2462]・[#3712] |

## 保持した形

4 件。`loadShape()` の下の 2 行は子の行で、件数に入れない。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `createShape()` | `createShape(_:)` | 同等 | クロージャの中で `beginShape()` や図形の API を呼んで組み、`setup()` で 1 度だけ作る。**色・線の太さ・断片は形に焼き付き、置くときの外の `fill` は効かない。** 無い形: 空の形を返して後から `beginShape()` を呼ぶ形と、種類を渡す形 (`createShape(RECT, a, b, c, d)` ほか。`createShape { rect(a, b, c, d) }` と書く) | [#788] |
| `loadShape()` | `loadShape(_:)`・`requestShape(_:)` | 同等 | SVG を読み、`createShape { }` と同じ `Shape` にする。読めないときは投げる (Processing は `null`)。無い形: URL から読むこと・OBJ を `Shape` として読むこと (OBJ は `loadModel(_:normalize:)` が `Model` として読む) | [#2019]・PR [#2192] |
| `shape()` | `shape(_:_:_:)`・`shape(_:at:)` | 同等 | 位置を省けば、動かした原点に置く。大きさは `scale(_:_:)` か `Placement` の `scale` で変える。無い形: 幅と高さを渡す `shape(shape, a, b, c, d)` (`shapeMode()` と組で、下の行) | — |
| `shapeMode()` | — | 作例待ち | `shape()` の 3・4 番目の数の読み方 (`CORNER`・`CORNERS`・`CENTER`) を変える状態で、幅と高さを渡す形と組になる。割れる点は、**形自身の大きさを何とするか**。Processing の `PShape.getWidth()` は、既定の描き手 (JAVA2D) では描く領域の大きさ (SVG なら `width` か `viewBox`。ソースに「形の境界とは限らない」とある) で、P2D・P3D では頂点の広がりと、描き手で違う。mokume の `Shape.bounds` は描くものの外接 (線の太さを含まず、平面の部分が無ければ `nil`) で、SVG の `viewBox` の大きさは持たない。中心に置くにも、どれの中心かが割れる。いまは `bounds` の `center` を引いて置く (`shape(read, -box.center.x, -box.center.y)`) | [#2426]・PR [#3098] |

### `loadShape()` の下の子の行 (件数に入れない)

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| └ `loadShape()` が読む SVG の `<linearGradient>`・`<radialGradient>` | — (読まず、捨てたものとして報告する) | 入れる | Processing 4.5.7 は読む。`PShapeSVG.java` が `stop` の色と不透明度・`x1`〜`y2`・`cx`・`cy`・`r`・`gradientTransform` を読み、塗るのは JAVA2D の描き手だけ (`PShapeJava2D.java` の `calcGradientPaint`・`styles()`。`PShapeOpenGL.java` に勾配を扱うコードは無い)。`spreadMethod`・`gradientUnits`・`fx`・`fy`・`href` による継承は読まない。mokume には勾配の型 (`Gradient`) と描く状態の勾配 (`fill(_: Gradient)`) があり、読めない書き方は捨てて報告する道が既にある。割れる点が無く、Processing の範囲を目安にできる。置く前の勾配が読んだ SVG に効かないこと ([#3008] の仕様) は変わらない。[#3031] は `Feature` として開いているので、作例を待たずにラベルを付けられる | [#3031]・[#3008]・PR [#3009] |
| └ `loadShape()` が読む OBJ の材質 (`mtllib`・`usemtl`・MTL の `Kd`・`Ka`・`Ks`・`Ns`・`d`)・拡散テクスチャ (`map_Kd`)・グループ名 (`g`) | — (`loadModel` は形・法線・UV だけを読み、材質・テクスチャ・物体の区切りは読み飛ばす) | 作例待ち | Processing 4.5.7 は読む (`PShapeOBJ.java`)。`Kd`・`Ka`・`Ks`・`Ns`・`d` を面ごとの色と光沢に、`map_Kd` を拡散テクスチャに使う。**面ごとに子の形を 1 つ作るが、`g` の名前は子に渡さず、読み返す所も無い** (`OBJFace.name` に控えるだけ)。グループ名から `getChild(名前)` では引けず、番号の `getChild(index)` だけ引ける。割れる点は、**材質の表現を 1 つにする** こと。OBJ 専用の材質の型を先に公開せず、[#2607] の glb と同じ表現に載せる。読んだ材質と作品が呼んだ `fill`・`texture` のどちらが勝つか、欠けた MTL・テクスチャの扱いも決まっていない。OBJ を `Shape` でなく `Model` として読む形 (上の `loadShape()` の行) も、そこで決める | [#3476]・[#2607] |

## PShape

26 件。クラスの頁 1 件と、メンバー 25 件 (`beginContour()`・`endContour()` と、category の無い `getChildCount()`・`setFill()`・`setStroke()` を含む)。

| API | mokume の API | 区分 | 理由 | 根拠の Issue・PR |
| --- | --- | --- | --- | --- |
| `PShape` (クラス) | `Shape` | 同等 | 保持した形の型。焼いた頂点の並びの値で、木を作らず、組にしても描く回数が増えない (`Shape.group(_:)`・`+`)。子の一覧・頂点の読み書き・変換・表示の旗・色の差し替えは持たない (下の各行) | [#788]・[#2426] |
| `PShape.width`・`PShape.height` (2 件) | `Shape.bounds` の `width`・`height` | 同等 | 平面の部分の外接矩形を、形自身の座標で返す。**描くものの外接で、線の太さを含まない。** Processing の参照は「文書の大きさ」と書き、既定の描き手 (JAVA2D) では SVG の `width` か `viewBox` の大きさなので、余白のある SVG では値が違う (P2D・P3D は頂点の広がりで、こちらに近い)。平面の部分が無い形 (立体だけ・`Shape.empty`) は `nil` を返す | [#2426]・PR [#3098] |
| `PShape.beginShape()`・`endShape()`・`beginContour()`・`endContour()` (4 件) | `createShape { }` の中の `beginShape(_:)`・`endShape(_:)`・`beginContour()`・`endContour()` | 持たない | 形に頂点を足すメソッドは、形の上に持たない。クロージャの中で、スケッチと同じ API で組む。組んだ後は書き換えない | [#788] |
| `PShape.addChild()` | `Shape.group(_:)`・`+` | 持たない | 組にするのは形の上の静的メソッドで、繋ぐだけの 1 本の並びになる (木を作らない)。足す番号を指す形 (`addChild(who, idx)`) は無い | — |
| `PShape.isVisible()`・`setVisible()` (2 件) | `if` で `shape(_:)` を呼ぶか決める | 持たない | 形は表示の旗を持たない。描くかどうかは `shape(_:)` を呼ぶかで決める (Swift の言語) | — |
| `PShape.resetMatrix()`・`rotate()`・`rotateX()`・`rotateY()`・`rotateZ()`・`scale()`・`translate()` (7 件) | `translate`・`rotate`・`scale` と `push()`・`pop()`、`Placement` | 持たない | 焼いた頂点を書き換えず、置くときの変換が同じ働きをする。形自身の座標を変えたいときは、`createShape { }` の中で変換を書く (中で書いた変換は形に焼き付く) | — |
| `PShape.getChild()` | — | 作例待ち | **[#2426] の決定 (2026-10-16) 「`id` で部分を取り出す API (`getChild`) は、要る作例が来るまで持たない」の写し。** 表で「入れる」を選べば、ADR-0041 決定 3 の改訂により作例なしで進めることになり、この決定の選び直しになる。[#3471] (not planned) の閉じるコメントも、表で「入れる」と選ばれたら開き直さず、その種類の `Feature` を立てるとする。割れる点は、子を引く編集用の表現を `Shape` に足すか別の型にするか ([#3471] の B) と、名前を SVG の `id` から取るか。Processing の SVG は子の名前に `id` を使い、`getChild(名前)` は木全体を探す。OBJ の子には名前が無い (`loadShape()` の OBJ の行)。無い形: 番号の `getChild(index)` | [#2426]・[#3471] |
| `PShape.getVertexCount()`・`getVertex()`・`setVertex()` (3 件) | — (`Shape.vertexCount` は別の数) | 作例待ち | 作者が組んだ頂点は、`Shape` に残らない。残るのは三角形に割った頂点で、`Shape.vertexCount` はその数であり、距離関数で描く基本図形 (矩形・楕円・線・点) は 0 と数える。割れる点は、何を頂点と呼ぶか (組んだ点を別に持つか、`Path` の点か) と、書き換えを値の型でどう表すか (`mutating` か、書き換えた写しを返すか)。[#2426] の `getChild` と同じく、編集用の表現が決まるまで待つ。いまは自分の配列に点を持ち、`createShape { }` で組み直す | [#2426]・[#3471] |
| `PShape.disableStyle()`・`enableStyle()` (2 件) | — (置き場所に色を掛ける `Placement.fill`) | 作例待ち | 形の色と線を捨てて、いまの `fill()`・`stroke()` で描く。mokume は色を形に焼き付けると決めている ([#788]・[ADR-0045](../decisions/0045-game-direction.md))。[#3008] は「明示して有効にする API で、置くときに記録した塗りを捨てる」案 (B) を採らず、「作例が来たときに選ぶ」とした。[#2019] の完了報告も同じ。割れる点は、捨てるのが色だけか線の太さ・端の形までか。いまは白で描いた形に `Placement.fill` で色を掛ける (色だけ) | [#3008]・[#2019] |
| `PShape.getChildCount()` | — | 作例待ち | `getChild()` と組。子を引く編集用の表現が決まるまで待つ | [#2426]・[#3471] |
| `PShape.setFill()`・`setStroke()` (2 件) | — (置き場所に色を掛ける `Placement.fill`) | 作例待ち | 組んだ後に形の色を差し替える API。`disableStyle()` と同じ割れ (色の差し替えを形の上に持つか、置き場所で掛けるか) で、同じ決定に従う | [#3008] |

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
