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

        /// ``beginDraw()`` を対にせず重ねて呼んだ。
        case alreadyDrawing
        /// ``beginDraw()`` の前に ``endDraw()`` を呼んだ。
        case notDrawing
        /// 描き切る前の描き場所を置いた。
        case placingWhileDrawing

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
        /// ``Canvas/index(_:)`` に、置いていない頂点の番号が渡された。
        case indexOutOfRange

        /// 無い書体を指定された。
        case missingFont
        /// 1 フレームで要る字が、焼き直しても上限の焼き場に収まらなかった。
        ///
        /// 以前の `atlasFull` (上限まで埋まった) を改めたもの。上限まで埋まるだけなら焼き
        /// 直して戻るので、知らせる場面ではなくなった ([#1342])。
        ///
        /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
        case atlasFullInOneFrame
    }
}
