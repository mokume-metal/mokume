// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 面が「初回だけ」言う注意の一覧。控えの仕組みは ``WarningLog`` が持つ。
extension Canvas {
    /// 1 度だけ言う注意の種類。
    ///
    /// **旗ではなく鍵で数える** ([#734])。ケース名は畳む前の `warnedXxx` から `warned`
    /// を落としたもので、名前が対応していれば履歴を辿るときに突き合わせが要らない。
    ///
    /// **同じ鍵を複数の場所から言うのは、同じ事情を別の入口から知らせるときだけ。** 例えば
    /// ``badCamera`` は、視点の口 (`camera()` / `setCamera()`)・投影の口 (`perspective()` /
    /// `ortho()`)・`setCamera()` が持ち込む投影の 3 か所が「視点が成り立たない」を共有する
    /// (畳む前から 1 つの旗だった)。共有するかどうかはこの定義を見れば分かる — 鍵が文字列
    /// なら、どれが黙っているかは誰にも分からない。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
        /// 塗りに、数でない値・無限の値が渡された。
        case notANumberFill
        /// 線の色に、数でない値・無限の値が渡された。
        case notANumberStroke
        /// 下地に、数でない値・無限の値が渡された。
        case notANumberBackground
        /// 画像に掛ける色に、数でない値・無限の値が渡された。
        case notANumberTint
        /// 塗りの不透明度が 0–255 の外で、締めた ([#1842])。**数でない値の注意とは鍵を分ける** —
        /// あちらは塗りを変えずに断り、こちらは締めて塗る。口ごとに数える (下の 3 つも同じ)。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedFillOpacity
        /// 線の色の不透明度が 0–255 の外で、締めた ([#1842])。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedStrokeOpacity
        /// 下地の不透明度が 0–255 の外で、締めた ([#1842])。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedBackgroundOpacity
        /// 画像に掛ける色の不透明度が 0–255 の外で、締めた ([#1842])。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedTintOpacity
        /// 底上げの光に、数でない値・無限の値が渡された。
        case notANumberAmbientLight
        /// 向きを持つ光に、数でない値・無限の値が渡された。
        case notANumberDirectionalLight
        /// 位置を持つ光に、数でない値・無限の値が渡された。
        case notANumberPointLight
        /// 広がりを持つ光に、数でない値・無限の値が渡された。
        case notANumberSpotLight
        /// 広がりを持つ光の半頂角 (`angle`) に、0…π/2 の外の値 (数でない値を含む) が渡され、
        /// 範囲へ丸めた ([#1698])。
        ///
        /// **``notANumberSpotLight`` とは鍵を分ける。** あちらは光を置かず、こちらは丸めて置く。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case badSpotLightAngle
        /// 光を受けて返す色に、数でない値・無限の値が渡された。
        case notANumberAmbient
        /// 自分で出す光に、数でない値・無限の値が渡された。
        case notANumberEmissive

        /// 勾配 (``Gradient``) を受けられなかった。区切りが無い・数でない値・点がつぶれている (#2433)。
        case badGradient
        /// 勾配の区切りが多すぎて、位置の小さい順に上限までを使った (#2433)。
        case tooManyGradientStops
        /// 勾配の断片を組めなかった (#2433)。
        case gradientUnavailable

        /// 面の無いモデルを置いた。
        case emptyModel
        /// 読んだモデルに、壊れて読み飛ばした行 (読めない頂点・面・仕様に無い語) や面があった (#2565)。
        /// **ファイルの名前ごとに 1 度** — 名前はスケッチの文字に書かれたものなので、鍵の数はフレームで増えない。
        /// 意図して読まない行 (`mtllib`・`usemtl` など) では言わない。
        case modelSkipped(path: String)
        /// 読んだ SVG に描けないものがあって捨てた、または描くものが 1 つも無かった。**ファイルの
        /// 名前ごとに 1 度** — 名前はスケッチの文字に書かれたものなので、鍵の数はフレームで増えない。
        case svgSkipped(path: String)
        /// 読んだ SVG の `opacity` を、子ごとに掛ける近似で描いていて、重なった所が SVG より濃く出る
        /// (#2884)。**ファイルの名前ごとに 1 度**。捨てたもの (``svgSkipped(path:)``) とは別の知らせ —
        /// 描いてはいる。層の `opacity` を本体が持てば ([#2878]) 消える。
        ///
        /// [#2878]: https://github.com/mokume-metal/mokume/issues/2878
        case svgApproximated(path: String)
        /// 置けない置き場所が混ざっていた。
        case badPlacement
        /// 数の並びを置き場所として読む口 (``Canvas/shape(_:at:layout:)``) に、その道に載らない形が渡された。
        /// 理由は文面に並べる。鍵は 1 つで、初めに言った文面が残る (``badPlacement`` と同じ)。
        case positionLayoutShape
        /// 数の並びを置き場所として読む口に、3 で割り切れない長さの並びが渡された。端数は置かない。
        case positionLayoutRemainder
        /// 数の並びを置き場所として読む口が、計算の入口か置き場を用意できなかった。
        case positionLayoutUnavailable
        /// 立体の寸法が受け取れない値だった。
        case badSolidSize
        /// ``sphere(_:detail:)`` の分け方に、範囲 (``SolidShape/detailRange``) の外の値が渡され、
        /// 範囲へ丸めた ([#1698])。
        ///
        /// **立体ごとに鍵を分ける** (#1698 の反証 9)。範囲は 5 つの立体で同じだが、共有すると
        /// 先に言った立体が後の立体の書き間違いを黙らせる。`textSize` と `textLeading` を分けた
        /// のと同じ理由である。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case badSphereDetail
        /// ``ellipsoid(_:_:_:detail:)`` の分け方を丸めた。分ける理由は ``badSphereDetail``。
        case badEllipsoidDetail
        /// ``cylinder(_:_:detail:)`` の分け方を丸めた。分ける理由は ``badSphereDetail``。
        case badCylinderDetail
        /// ``cone(_:_:detail:)`` の分け方を丸めた。分ける理由は ``badSphereDetail``。
        case badConeDetail
        /// ``torus(_:_:detail:)`` の分け方を丸めた。分ける理由は ``badSphereDetail``。
        case badTorusDetail

        /// フレームの外で光を置いた。
        case lightOutsideFrame
        /// フレームの外で材質を書いた。
        case materialOutsideFrame
        /// 受け取れない材質の値が渡された。
        case badMaterial
        /// 受け取れない露出が渡された。
        case badExposure
        /// 光も周囲も無いところで材質を書いた。
        case materialWithoutLight
        /// 映す先が無いまま金属を上げた。
        case metalWithoutSurroundings

        /// フレームの外で周囲を置いた。
        case surroundingsOutsideFrame
        /// 受け取れない周囲が渡された。
        case badSurroundings
        /// 受け取れない揺らぎの設定が渡された。
        case badNoise

        /// 効果の引数に、数でない値・無限の値が渡された ([#1544])。
        ///
        /// [#1544]: https://github.com/mokume-metal/mokume/issues/1544
        case badEffect
        /// 効果の `amount` が 0…1 の外で、端へ締めた ([#1842])。効果と量ごとに鍵を分ける —
        /// 別の効果の注意を黙らせない。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedBloomAmount
        case roundedInvertAmount
        case roundedMonochromeAmount
        case roundedVignetteAmount
        case roundedFringeAmount
        /// ``Effect/threshold(level:)`` の `level` が 0…1 の外で、端へ締めた。
        case roundedThresholdLevel
        /// 効果の `radius` が ``Effect/maxRadius`` を越え、そこへ締めた ([#1842])。
        ///
        /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
        case roundedBlurRadius
        case roundedBloomRadius
        /// フレームの外で効果を決めた ([#1605])。
        ///
        /// [#1605]: https://github.com/mokume-metal/mokume/issues/1605
        case effectsOutsideFrame
        /// 効果を通せなかった (フレームの終わりの ``Canvas/effects(_:)``)。
        case effectFailed
        /// ``Canvas/filter(_:)`` が、持ち越しを約束する区間の外で呼ばれた。置いたもの (``OutsideFrame/placing``) と
        /// 同じ区間で許すので、シーンの記述の鍵 (``effectsOutsideFrame``) とは分ける — 直す先の言い方が違う。
        case filterOutsideFrame
        /// ``Canvas/filter(_:)`` が効果を通せなかった。``effectFailed`` と文面が違う (こちらは絵がそのまま残る)。
        case filterFailed
        /// ``Canvas/filter(_:)`` が呼んだ投入を、GPU が打ち切った。絵は掛ける前のまま残る (打ち切られた投入は
        /// 1 画素も書かない)。
        case filterDropped
        /// 受け口の注意 (``badEffect``・`rounded…`) を、``Canvas/effects(_:)`` ではなく ``Canvas/filter(_:)`` と
        /// ``Image/filtered(_:)`` の口から言うときの鍵。**口ごとに鍵を分ける** — `effects()` で 1 度出した注意が、
        /// 同じ面の `filter()` の注意を面の寿命のあいだ黙らせない (失敗の鍵と区間の外の鍵を分けたのと同じ理由)。
        /// 文面は呼んだ口の名前を名乗るので、どちらの口の書き違えかを指さす。
        indirect case filterSide(Warning)
        /// 作業の面を作れず、``Image/filtered(_:)`` が効果を掛けない写しを返した。大きさごとに 1 度だけ言う。
        case filteredWorkspaceUnavailable
        /// GPU が打ち切った効果のフレームの後に、次のフレームがもう戻していた ([#2388])。効果が焼き込まれたまま
        /// 残りうる。
        ///
        /// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
        case effectBakedAfterDrop
        /// 拡大を通せなかった。
        case upscaleFailed
        /// 止まっている間のコールバックが書いた画素を、配った直後に描く先へ書き戻せなかった
        /// (細かさ 1 の面・[#1906])。書き込み待ちは残り、次のリフレッシュと出力段がやり直す。
        ///
        /// **``upscaleFailed`` とは鍵を分ける。** 細かさ 1 の面には拡大の段が無く、あちらの文面は
        /// 直す先を指さない。細かさを下げた面の追い付きは書き戻しと拡大を 1 本で積むので、
        /// あちらの鍵で言う。
        ///
        /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
        case pixelWriteBackFailed

        /// フレームの外で粒を扱った。
        case particlesOutsideFrame
        /// フレームの外で計算を頼んだ。
        case computeOutsideFrame
        /// 1 回の計算に束ねられる本数を超えた。
        case tooManyComputeBuffers
        /// 別の面のぶつかる頼みのために、この面の未投入の計算を先に投入しようとして失敗した
        /// ([#1870])。計算は溜めたまま、この面の描き切りが流す。
        ///
        /// [#1870]: https://github.com/mokume-metal/mokume/issues/1870
        case computationsSentAheadFailed

        /// フレームの外で影の設定を書いた。
        case shadowOutsideFrame
        /// 受け取れない影の値が渡された。
        case badShadow
        /// 影を落とすと言ったまま、向きを持つ光を 1 本も置かずにフレームを終えた。
        case shadowWithoutCaster

        /// フレームの外で視点を書いた。
        case cameraOutsideFrame
        /// フレームの外で変換を書いた。
        case transformOutsideFrame
        /// 持ち越しの区間 (`setup()`・止まっている間のコールバック) で変換を書いたのに、その後に何も置かないまま
        /// 区間を出た ([#3273])。変換は区間を出るとき戻り、`draw()` へは持ち越さない。
        ///
        /// **``transformOutsideFrame`` とは鍵を分ける。** あちらは変換を断った (区間の外・効かなかった) 話で、
        /// こちらは効かせたうえで、置くものが無く捨てた話である。
        ///
        /// [#3273]: https://github.com/mokume-metal/mokume/issues/3273
        case transformNotCarried
        /// フレームの内側で配る入力のコールバック (ループ中・`redraw()` を頼んだ後) で、影・効果・目印を書いたまま
        /// 抜けた ([#3408])。これらは列に焼かれず描き切りで読まれるので、出口で戻すと同じフレームの `draw()` に届かない。
        ///
        /// **``transformNotCarried`` とは鍵を分ける。** あちらは止まっている間の区間の話で、こちらはフレームの
        /// 内側の話である。
        ///
        /// [#3408]: https://github.com/mokume-metal/mokume/issues/3408
        case sceneNotCarried
        /// フレームの外でスタイルを積み降ろしした。
        case styleOutsideFrame
        /// フレームの外で切り抜きを書いた。
        case clipOutsideFrame
        /// フレームの外で目印の格子と軸 (`debugMode()` / `noDebugMode()`) を書いた ([#2462])。
        ///
        /// [#2462]: https://github.com/mokume-metal/mokume/issues/2462
        case debugOutsideFrame
        /// 成り立たない視点・投影が渡された。**入口が 3 つある 1 つの事情** — 視点の口・
        /// 投影の口・`setCamera()` が持ち込む投影 ([#1495])。
        ///
        /// [#1495]: https://github.com/mokume-metal/mokume/issues/1495
        case badCamera
        /// ``SketchPart/orbitControl(_:_:_:)`` の感度に、数でない値・無限の値が渡され、
        /// その軸を効かせなかった ([#2643])。
        ///
        /// **``badCamera`` とは鍵を分ける。** あちらは視点を当てず、こちらは視点を当てる。
        /// 下の 2 つとも分ける — こちらは受け口に渡された値、あちらは進めた結果と書かれた値の話。
        ///
        /// [#2643]: https://github.com/mokume-metal/mokume/issues/2643
        case badOrbitSensitivity
        /// 有限の感度で、引きずった量・スクロールとの積が数でない・無限になり (溢れた・
        /// 届いた量が無限)、その軸をそのフレームだけ進めなかった ([#2643])。
        case orbitStepHeld
        /// ``SketchPart/orbit`` に収めようのない値 (数でない値・無限の角など) が書かれ、
        /// 既定へ倒した ([#2643])。
        case badOrbit
        /// 受け取れない切り抜きが渡された (数でない値・無限の指定)。
        case badClip
        /// 渡された 4 つの数は有限だが、`rectMode(_:)` で矩形へ解くと端が数でなくなった (`.radius` の
        /// `-∞ + ∞`)。切り抜きは触らない ([#2721])。
        ///
        /// **``badClip``・``clipTransformOverflow`` とは鍵を分ける。** 直す先が違い (渡す数・変換)、同じ鍵だと
        /// 先に出た文面が後の原因を隠す。
        ///
        /// [#2721]: https://github.com/mokume-metal/mokume/issues/2721
        case clipNotResolvable
        /// 渡された数は有限で矩形にも解けたが、いまの変換が矩形を数でない値・無限へ運んだ (倍率が大きすぎる・
        /// 行列が溢れている)。切り抜きは触らない ([#2721])。
        ///
        /// **``badClip``・``clipNotResolvable`` とは鍵を分ける。**
        ///
        /// [#2721]: https://github.com/mokume-metal/mokume/issues/2721
        case clipTransformOverflow
        /// 回転・剪断を含む変換の下で ``Canvas/clip(_:_:_:_:)`` が呼ばれ、写した 4 つの角を囲む面に沿った
        /// 矩形で切り抜いた ([#2721])。切り抜きは面に沿った矩形しか持てない。
        ///
        /// **``badClip`` とは鍵を分ける。** あちらは渡された数が受け取れない話で、こちらは数は受け取れて、
        /// 変換の下で表せない形を近似した話である。
        ///
        /// [#2721]: https://github.com/mokume-metal/mokume/issues/2721
        case clipUnderRotation
        /// ``strokeWeight(_:)`` に負の値・数でない値・無限が渡され、0 に丸めた ([#1698])。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case badStrokeWeight
        /// ``strokeDash(_:_:)`` に負の値・数でない値・無限・両方 0 が渡され、破線を置かずに実線へ
        /// 戻した ([#2835])。
        ///
        /// [#2835]: https://github.com/mokume-metal/mokume/issues/2835
        case badStrokeDash
        /// 破線が線の長さに対して細かすぎ、刻む数が上限を越えるので、その線を実線で引いた ([#2835])。
        ///
        /// [#2835]: https://github.com/mokume-metal/mokume/issues/2835
        case strokeDashTooFine
        /// 特化した立体のパイプライン (光の枝を外した組・ブレンドを外した組) を組めず、その立体を既定の
        /// パイプラインで描いた ([#1795]・[#2366])。絵は同じで、速さだけが戻る。
        ///
        /// [#1795]: https://github.com/mokume-metal/mokume/issues/1795
        /// [#2366]: https://github.com/mokume-metal/mokume/issues/2366
        case solidVariantUnavailable
        /// ``rect(_:_:_:_:_:)`` の角の半径に負の値・数でない値が渡され、0 に丸めた ([#2757])。
        /// 角を丸めない 4 引数と同じ絵になる。
        ///
        /// [#2757]: https://github.com/mokume-metal/mokume/issues/2757
        case badCornerRadius

        /// 同じ本体のフレームの中で ``beginDraw()`` を対にせず重ねて呼んだ。境目を越えて
        /// いないので、何もせず開いているフレームが続く。
        case alreadyDrawing
        /// ``beginDraw()`` で開いたフレームを ``endDraw()`` で閉じないまま境目を越えた。閉じて
        /// いなかったフレームは描かずに捨てる ([#1622])。描き場所では本体の次のフレームの頭で
        /// 捨て、本体・直に使う面では自分の次のフレーム (`beginDraw()` か `draw { }`) の頭で捨てて
        /// 描き始め直す ([#1834])。捨てた事情は 1 つなので鍵を共有し、文面は起きたことを名乗る。
        ///
        /// **``alreadyDrawing`` とは鍵を分ける。** あちらは境目を越えていない重ね呼びで、中身を
        /// 保つ。振る舞いが違う。
        ///
        /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        case unfinishedFrameDropped
        /// ``draw(_:)`` が開いたフレームの中で、フレームを開く・閉じる口 (``beginDraw()``・
        /// ``endDraw()``・入れ子の ``draw(_:)``) を呼んだ。フレームは開き直さず閉じもしない。
        ///
        /// 入口は 3 つで事情は 1 つなので鍵を共有し、文面は口ごとの全文にする。
        case frameCallInsideDraw
        /// ``beginDraw()`` の前に ``endDraw()`` を呼んだ。
        case notDrawing
        /// 描き場所で、閉じ忘れたまま本体のフレームが進んで捨てた後に ``endDraw()`` を呼んだ
        /// ([#1834])。
        ///
        /// **``notDrawing`` とは鍵を分ける。** あちらは `beginDraw()` を書いていない誤りで、
        /// こちらは `endDraw()` が遅れた誤りである。直す先が違う。
        ///
        /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
        case endDrawAfterFrameDropped
        /// 描き切る前の描き場所を置いた。
        case placingWhileDrawing
        /// 持ち越しを約束する区間の外で、図形・絵・背景を置いた ([#1672])。
        ///
        /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        case placingOutsideFrame
        /// 持ち越しを約束する区間の外で、画素を書いた ([#1672])。
        ///
        /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        case pixelWriteOutsideFrame
        /// フレームの頭の検めが、守りの無い道で置かれたものを見つけた ([#1682])。**mokume の
        /// 中の不具合**を名乗る注意で、利用者の書き方の誤りではない。
        ///
        /// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
        case placementLeak

        /// 角度が逆向きの円弧を描こうとした。
        case reversedArc
        /// 形の外 (``beginShape(_:)`` と ``endShape(_:)`` の間でないところ) で、頂点の仲間を
        /// 呼んだ ([#1498])。
        ///
        /// 入口は ``vertex(_:_:)`` (4 つの形)・``bezierVertex(_:_:_:_:_:_:)``・
        /// ``quadraticVertex(_:_:_:_:)``・``curveVertex(_:_:)``・``beginContour()``・
        /// ``endContour()``・``normal(_:_:_:)``・``index(_:)`` の 8 つで、事情は 1 つなので鍵を
        /// 共有する。文面には呼んだ関数の名前が入る。``endContour()`` と ``normal(_:_:_:)``
        /// は #1520 で加わった — 直す前は、形の外では注意なしで黙っていた。
        ///
        /// [#1498]: https://github.com/mokume-metal/mokume/issues/1498
        case vertexOutsideShape
        /// 形の始まりが無いまま ``endShape(_:)`` を呼んだ ([#1520])。一度も
        /// ``beginShape(_:)`` を呼んでいない場合と、二重に呼んだ場合の 2 つがここに来る。
        ///
        /// **``vertexOutsideShape`` とは鍵を分ける。** あちらの文面 (`beginShape()` と
        /// `endShape()` の間で呼べ) は `endShape()` には直す先を指さない。対の終わりを
        /// 始まり無しに呼んだことを別の鍵で言うのは、``notDrawing`` と同じ形である。
        ///
        /// [#1520]: https://github.com/mokume-metal/mokume/issues/1520
        case shapeNotBegun
        /// ``beginShape(_:)`` で開いた形を ``endShape(_:)`` で閉じないまま、フレームの境目を
        /// 越えた ([#1591])。形は描かずに捨てる。
        ///
        /// **``shapeNotBegun``・``vertexOutsideShape`` とは鍵を分ける。** あちらは対の片方を
        /// 呼んだ場所の誤りで、こちらは開いた形を閉じ忘れたまま境目が来たことを言う。閉じ
        /// 忘れた形を捨てた後の `vertex()` は形の外になるので、同じ書き間違いから 2 つとも
        /// 出ることがある — 共有すると、先に言った側がもう片方を黙らせる。
        ///
        /// [#1591]: https://github.com/mokume-metal/mokume/issues/1591
        case shapeNotEnded
        /// 戻す段が無いのに ``pop(fileID:line:)``・``popMatrix(fileID:line:)``・``popStyle(fileID:line:)``
        /// を呼んだ ([#2399])。何もしない。3 つの口は同じ「対の無い降ろし」を言うので鍵を共有する。
        ///
        /// [#2399]: https://github.com/mokume-metal/mokume/issues/2399
        case popWithoutPush
        /// 積んだ段を降ろさないまま、フレーム・形の組み立て・``push(_:)`` の本体が終わった ([#2399])。
        /// 段は戻さずに捨てる。**``popWithoutPush`` とは鍵を分ける** — 早期 `return` は片方だけを
        /// 起こすが、余分な `pop()` と取り違えた積み忘れは両方を起こし、共有すると先の側がもう片方を黙らせる。
        ///
        /// [#2399]: https://github.com/mokume-metal/mokume/issues/2399
        case pushLeftOpen
        /// ``beginShape(_:)`` で開いた形を ``endShape(_:)`` で閉じないまま、同じ本体の中で
        /// ``beginShape(_:)`` をもう一度呼んだ ([#1608])。前の形は描かずに捨てる。
        ///
        /// **``shapeNotEnded`` とは鍵を分ける。** あちらの文面は開いた本体の終わりを越えたと
        /// 名乗り、こちらは本体の終わりを越えていない。同じ閉じ忘れから両方が出ることもある
        /// (重ねた後の形も閉じ忘れて本体を抜ける) ので、共有すると先に言った側がもう片方を
        /// 黙らせる。
        ///
        /// [#1608]: https://github.com/mokume-metal/mokume/issues/1608
        case shapeBegunWhileOpen
        /// 形の中で、穴を開かずに ``endContour()`` を呼んだ ([#1528])。
        ///
        /// 形の外で呼んだときは ``vertexOutsideShape`` のほうを言う (直す先が
        /// `beginShape()` で、こちらは `beginContour()`)。
        ///
        /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
        case contourNotBegun
        /// 形の中で、向きにならない値 (数でない・無限・長さ 0) を ``normal(_:_:_:)`` に
        /// 渡した ([#1528])。向きは「書かれていない」に倒す。
        ///
        /// ``badVertex`` とは鍵を分ける。あちらの文面は置かなかった頂点のことを言い、向きには
        /// 当てはまらない。形の外で呼んだときは ``vertexOutsideShape`` のほうを言う。
        ///
        /// [#1528]: https://github.com/mokume-metal/mokume/issues/1528
        case badNormal
        /// 形の中で、手前に点が無いまま曲線を続けようとした ([#1485])。
        ///
        /// 入口は ``bezierVertex(_:_:_:_:_:_:)`` と ``quadraticVertex(_:_:_:_:)`` の 2 つで、
        /// 事情は 1 つなので鍵を共有する。文面には呼んだ関数の名前が入る。穴
        /// (``beginContour()``) の最初もこれに当たる — 穴は外周の点から始めない。
        ///
        /// [#1485]: https://github.com/mokume-metal/mokume/issues/1485
        case curveWithoutStart
        /// 受け取れない頂点の座標が渡された。
        case badVertex
        /// ``curveDetail(_:)`` に 1…1024 の外の刻みの数が渡され、範囲の端へ丸めた
        /// (下の端は [#1698]・上の端は [#1692])。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        /// [#1692]: https://github.com/mokume-metal/mokume/issues/1692
        case badCurveDetail
        /// ``Canvas/index(_:)`` に、置いていない頂点の番号が渡された。
        case indexOutOfRange

        /// 無い書体を指定された。
        case missingFont
        /// ``Canvas/textFont(_:)`` で確かめた名前の書体が、書体を作る時には引けなかった ([#2772])。実行中に
        /// 書体を外したときに起きる。CoreText は別の書体を黙って返すので、返った書体の名前を添えて知らせる。
        ///
        /// **``missingFont`` と鍵を分ける。** 共有すると、`textFont()` に無い名前を渡した知らせが、先に
        /// 出ているだけで書体を外された知らせを黙らせる (逆も同じ)。
        ///
        /// [#2772]: https://github.com/mokume-metal/mokume/issues/2772
        case unavailableFont
        /// ``Canvas/textStyle(_:)`` の太さ・傾きの面を、書体が持っていなかった ([#2444])。
        ///
        /// [#2444]: https://github.com/mokume-metal/mokume/issues/2444
        case missingTypefaceStyle
        /// ``Canvas/textWeight(_:)`` の太さに、書体が近い面を持っていなかった ([#2445])。持つ面のうち最も近い
        /// ものを使ったが、頼んだ太さから大きく離れている。
        ///
        /// **``missingTypefaceStyle`` と鍵を分ける** — 太字の面の知らせが、太さの知らせを黙らせない。
        ///
        /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
        case missingTypefaceWeight
        /// ``Canvas/textWeight(_:)`` に、100〜900 の外の値が渡され、範囲の端へ丸めた ([#2445])。
        ///
        /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
        case badTextWeight
        /// ``Canvas/textWeight(_:)`` に、数でない値・無限が渡された。太さは前のまま ([#2445])。
        ///
        /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
        case notANumberTextWeight
        /// 指定した書体が覆えず別の書体から引いた字の面が、``Canvas/textStyle(_:)`` の太さ・傾きを
        /// 持っていなかった ([#2561])。色の字形を持つ書体から引いた字と、墨を持たない字は数えない
        /// (``Typeface/lacksStyle(fallback:glyph:requested:)``)。
        ///
        /// **``missingTypefaceStyle`` と鍵を分ける。** 共有すると、指定した書体の面の知らせと
        /// 代わりの書体の面の知らせのうち、先に言った側がもう片方を黙らせる — どちらも
        /// 「効かない指定を効いたように見せる」ことを防ぐ知らせで、片方で他方は分からない。
        ///
        /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
        case missingFallbackTypefaceStyle
        /// ``Canvas/textSize(_:)``・``Canvas/textLeading(_:)`` に、数でない値・無限・上限
        /// (``Canvas/largestTextMeasure``) を越える値が渡された ([#1587])。
        ///
        /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
        case unusableTextMeasure
        /// ``Canvas/textOutline(_:_:_:spacing:)`` の `spacing` が、0 以下・数でない値・無限だった。
        /// または、小さすぎて 1 つの周の点が上限 (``Canvas/mostPointsPerContour``) を越えた ([#2447])。
        ///
        /// [#2447]: https://github.com/mokume-metal/mokume/issues/2447
        case invalidTextOutlineSpacing
        /// ``Canvas/textSize(_:)`` に負の値が渡され、0 に丸めた ([#1698])。
        ///
        /// **``unusableTextMeasure`` とも ``negativeTextLeading`` とも鍵を分ける。** 共有すると、
        /// 先に言った側 (数でない行送りなど) が負の大きさの知らせを黙らせる。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case negativeTextSize
        /// ``Canvas/textLeading(_:)`` に負の値が渡され、0 に丸めた ([#1698])。鍵を分ける
        /// 理由は ``negativeTextSize`` と同じ。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case negativeTextLeading
        /// 1 フレームで要る字が、焼き直しても上限の焼き場に収まらなかった。
        ///
        /// 以前の `atlasFull` (上限まで埋まった) を改めたもの。上限まで埋まるだけなら焼き
        /// 直して戻るので、知らせる場面ではなくなった ([#1342])。
        ///
        /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
        case atlasFullInOneFrame
        /// 拡大した字 (`textSize()` × `scale()`) が、1 字の大きさか頁の上限で、頼んだ段より低い段の画素で
        /// 描かれた ([#2446])。**``atlasFullInOneFrame`` とは鍵を分ける** — あちらは字が欠ける知らせで、
        /// こちらは欠けずに縁がぼける知らせである。
        ///
        /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
        case softEnlargedText

        /// 形の組み立て (``createShape(_:)``) の中で塗り直した ([#1588])。塗り 1 色の背景と周囲の
        /// 背景が鍵を共有する。種類と文面は ``InsideShape`` が持つ。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        case backgroundInsideShape
        /// 形の組み立ての中で、**組み立てている面自身の**画素を読み書きした ([#1588])。`get` / `set` /
        /// `pixels` / `loadPixels()` の 4 つが鍵を共有する (``vertexOutsideShape`` の前例)。組み立ての
        /// 途中の本体に置かれた描き場所の画素は、読み書きしても言わない ([#2203])。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        /// [#2203]: https://github.com/mokume-metal/mokume/issues/2203
        case pixelsInsideShape
        /// 形の組み立ての途中で溜め場が描き切られるか捨てられ、記録したものを失って空の形を返した
        /// ([#1588])。**mokume の不具合のときだけ出る** — 写しを持てなかった置いた描き場所の描き換えも、
        /// 組み立てた区間を残して置いた側の組み立ての前の列だけを描き切る ([#1855]・[#2201]・[#2509]・
        /// [#2850])。種類と文面は ``InsideShape`` が持つ。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
        /// [#2509]: https://github.com/mokume-metal/mokume/issues/2509
        /// [#2850]: https://github.com/mokume-metal/mokume/issues/2850
        case shapeDrawnOutWhileBuilding
        /// 組み立ての中で、組み立ての前に開いた自分のフレームを `endDraw()` で閉じようとした ([#1855])。
        /// フレームは閉じずに一番外の組み立ての出口まで待たせる。種類と文面は ``InsideShape`` が持つ。
        ///
        /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        case frameEndInsideShape
        /// 組み立ての中で、組み立てている面のフレームを始めようとした (`beginDraw()`・`draw { }`・
        /// [#2201])。フレームは始めない。種類と文面は ``InsideShape`` が持つ。
        ///
        /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
        case frameStartInsideShape
        /// 形の組み立ての中で、形に焼き付かない設定を書いた ([#1529])。種類ごとに鍵を分ける
        /// (``OutsideFrame`` と同じく、光の注意が視点の注意を黙らせない)。種類と文面は
        /// ``InsideShape`` が持つ。
        ///
        /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
        case cameraInsideShape
        case clipInsideShape
        case effectsInsideShape
        case filterInsideShape
        case lightInsideShape
        case surroundingsInsideShape
        case shadowInsideShape
        case materialInsideShape
        case particlesInsideShape
        case computeInsideShape
        case positionLayoutInsideShape
        case brightnessInsideShape
        case debugInsideShape
    }

    /// 範囲の外の値を範囲へ丸めたことを、初回だけ知らせる ([#1698])。
    ///
    /// 描画中に呼ぶ口は投げずに丸めるが、**丸めたことは言う** ([ADR-0020] 決定 5 の 1 行目:
    /// 警告を出して安全な既定へ倒す)。丸める口の文面をここ 1 か所で組むので、どの口も
    /// 口の名前・量・受け取れる範囲・渡した値・使った値を同じ順で名乗る。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    ///
    /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func warnRounded(
        _ warning: Warning, _ name: String, _ quantity: String, takes range: String,
        passed: some CustomStringConvertible, used: some CustomStringConvertible
    ) {
        warnOnce(
            warning,
            "\(name)(): \(quantity) takes \(range), but \(passed) was passed, so \(used) was used")
    }

    /// 色を受ける口が、数でない値・無限の値を断ったことを初回だけ知らせる ([#1706])。
    ///
    /// **数の形 (`fill(r, g, b)`) と色の値の形 (`fill(_: LinearRGBA)`) が、同じ鍵・同じ文面で
    /// 言う。** 文面はここ 1 か所で組むので、形によって言い方が変わらない。どちらの形も状態を
    /// 変えずに残す ([ADR-0020] 決定 5 の 1 行目: 警告を出して安全な既定へ倒す)。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func warnNotANumberColor(_ entry: ColorEntry) {
        warnOnce(
            entry.warning,
            "\(entry.rawValue)(): got a value that is not a number, or an infinite one, so \(entry.outcome)")
    }

    /// 不透明度を締めたことを、初回だけ知らせる ([#1842])。**範囲の中・数でない値は何も言わない**
    /// (数でない値は ``warnNotANumberColor(_:)`` が断る側)。
    ///
    /// 文面は ``warnRounded(_:_:_:takes:passed:used:)`` で組む。0–255 の目盛りの数の形も、色の値と
    /// 不透明度の形 (`fill(c, alpha)`) も、同じ鍵・同じ文面で言う。
    ///
    /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
    func warnRoundedOpacity(_ entry: ColorEntry, passed alpha: Float) {
        guard let warning = entry.roundedOpacityWarning,
            let used = DisplayScale.roundedOpacity(alpha)
        else { return }
        warnRounded(
            warning, entry.rawValue, "the opacity", takes: "0 to 255", passed: alpha, used: used)
    }

    /// 色を受ける口。注意の鍵と、断ったときに何を残したかを持つ。
    enum ColorEntry: String {
        case fill, stroke, background, tint
        case ambientLight, directionalLight, pointLight, spotLight
        case ambient, emissive

        var warning: Warning {
            switch self {
            case .fill: .notANumberFill
            case .stroke: .notANumberStroke
            case .background: .notANumberBackground
            case .tint: .notANumberTint
            case .ambientLight: .notANumberAmbientLight
            case .directionalLight: .notANumberDirectionalLight
            case .pointLight: .notANumberPointLight
            case .spotLight: .notANumberSpotLight
            case .ambient: .notANumberAmbient
            case .emissive: .notANumberEmissive
            }
        }

        /// 不透明度を締めたときの鍵。不透明度を持たない口 (光と質感) は `nil`。
        var roundedOpacityWarning: Warning? {
            switch self {
            case .fill: .roundedFillOpacity
            case .stroke: .roundedStrokeOpacity
            case .background: .roundedBackgroundOpacity
            case .tint: .roundedTintOpacity
            case .ambientLight, .directionalLight, .pointLight, .spotLight, .ambient, .emissive: nil
            }
        }

        var outcome: String {
            switch self {
            case .fill, .stroke, .background, .tint: "the colour was left as it was"
            case .ambientLight, .directionalLight, .pointLight, .spotLight: "no light was placed"
            case .ambient, .emissive: "the surface qualities were left as they were"
            }
        }
    }
}
