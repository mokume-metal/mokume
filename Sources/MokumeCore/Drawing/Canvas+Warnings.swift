// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 面が「初回だけ」言う注意の一覧。控えの仕組みは ``WarningLog`` が持つ。
extension Canvas {
    /// 1 度だけ言う注意の種類。
    ///
    /// **旗ではなく鍵で数える** ([#734])。ケース名は畳む前の `warnedXxx` から `warned`
    /// を落としたもので、名前が対応していれば履歴を辿るときに突き合わせが要らない。
    ///
    /// **同じ鍵を 2 か所から言うのは、同じ事情を別の入口から知らせるときだけ。** いま
    /// あるのは ``badCamera`` の 1 組で、`camera()` と `perspective()` / `ortho()` が
    /// 「視点が成り立たない」を共有する (畳む前から 1 つの旗だった)。共有するかどうかは
    /// この定義を見れば分かる — 鍵が文字列なら、どちらが黙っているかは誰にも分からない。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
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

        /// フレームの外で視点を書いた。
        case cameraOutsideFrame
        /// 成り立たない視点・投影が渡された。**入口が 2 つある 1 つの事情。**
        case badCamera

        /// ``beginDraw()`` を対にせず重ねて呼んだ。
        case alreadyDrawing
        /// ``beginDraw()`` の前に ``endDraw()`` を呼んだ。
        case notDrawing
        /// 描き切る前の描き場所を置いた。
        case placingWhileDrawing

        /// 角度が逆向きの円弧を描こうとした。
        case reversedArc
        /// 形の外で ``vertex(_:_:)`` を呼んだ。
        case vertexOutsideShape
        /// 受け取れない頂点の座標が渡された。
        case badVertex

        /// 無い書体を指定された。
        case missingFont
        /// 字形を焼く場所が上限まで埋まった。
        case atlasFull
    }
}
