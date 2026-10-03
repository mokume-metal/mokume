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

        /// 面の無いモデルを置いた。
        case emptyModel
        /// 置けない置き場所が混ざっていた。
        case badPlacement
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
        /// フレームの外で効果を決めた ([#1605])。
        ///
        /// [#1605]: https://github.com/mokume-metal/mokume/issues/1605
        case effectsOutsideFrame
        /// 効果を通せなかった。
        case effectFailed
        /// 拡大を通せなかった。
        case upscaleFailed

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
        /// フレームの外でスタイルを積み降ろしした。
        case styleOutsideFrame
        /// フレームの外で切り抜きを書いた。
        case clipOutsideFrame
        /// 成り立たない視点・投影が渡された。**入口が 3 つある 1 つの事情** — 視点の口・
        /// 投影の口・`setCamera()` が持ち込む投影 ([#1495])。
        ///
        /// [#1495]: https://github.com/mokume-metal/mokume/issues/1495
        case badCamera
        /// 受け取れない切り抜きが渡された。
        case badClip
        /// ``strokeWeight(_:)`` に負の値・数でない値・無限が渡され、0 に丸めた ([#1698])。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case badStrokeWeight

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
        /// ``Canvas/textSize(_:)``・``Canvas/textLeading(_:)`` に、数でない値・無限・上限
        /// (``Canvas/largestTextMeasure``) を越える値が渡された ([#1587])。
        ///
        /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
        case unusableTextMeasure
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

        /// 形の組み立て (``createShape(_:)``) の中で塗り直した ([#1588])。塗り 1 色の背景と周囲の
        /// 背景が鍵を共有する。種類と文面は ``InsideShape`` が持つ。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        case backgroundInsideShape
        /// 形の組み立ての中で画素を読み書きした ([#1588])。`get` / `set` / `pixels` /
        /// `loadPixels()` の 4 つが鍵を共有する (``vertexOutsideShape`` の前例)。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        case pixelsInsideShape
        /// 形の組み立ての途中で溜め場が描き切られ、記録したものを失って空の形を返した ([#1588])。
        /// 置いた描き場所の描き換えと、揺らぎの設定の書き換えがここへ来る。
        ///
        /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        case shapeDrawnOutWhileBuilding
        /// 形の組み立ての中で、形に焼き付かない設定を書いた ([#1529])。種類ごとに鍵を分ける
        /// (``OutsideFrame`` と同じく、光の注意が視点の注意を黙らせない)。種類と文面は
        /// ``InsideShape`` が持つ。
        ///
        /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
        case cameraInsideShape
        case clipInsideShape
        case effectsInsideShape
        case lightInsideShape
        case surroundingsInsideShape
        case shadowInsideShape
        case materialInsideShape
        case particlesInsideShape
        case computeInsideShape
        case brightnessInsideShape
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

        var outcome: String {
            switch self {
            case .fill, .stroke, .background, .tint: "the colour was left as it was"
            case .ambientLight, .directionalLight, .pointLight, .spotLight: "no light was placed"
            case .ambient, .emissive: "the surface qualities were left as they were"
            }
        }
    }
}
