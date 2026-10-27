// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// ベクターへ書く図形の値 ([ADR-0023] の改訂 (2026-10-23)・[#3139])。
//
// 画面を描く道 (三角形・距離関数) とは別の、**線そのものの記録**である。`Canvas` が置く口の内側で
// 控え (``Canvas/vector``)、`draw()` の終わりに隔離の外で ``SVGWriter`` が文字列にする。
// 座標は変換を当てた後の画面の座標で、1 単位は 1 画素・原点は左上・縦軸は下向き (SVG のユーザー
// 単位と同じ)。
//
// 隔離の外で組むので、型は全部 `nonisolated` で `Sendable` に保つ。
//
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
// [#3139]: https://github.com/mokume-metal/mokume/issues/3139

/// 1 本の道 (SVG の `d` の部分道 1 つ)。
nonisolated struct VectorSubpath: Sendable, Equatable {
    /// 道の点。最初が始点で、あとは部分ごとに並ぶ — 線は終点 1 つ、曲線は制御点 2 つと終点。
    /// ``curves`` が空なら、始点以外の点はすべて線の終点である (折れ線)。
    var points: [SIMD2<Float>]
    /// 部分ごとに、曲線か (偽は線)。**折れ線では空にする** — 1 万本・100 点の線に部分の数だけの
    /// 配列を持たせない。
    var curves: [Bool] = []
    /// 最後の点から最初の点へ戻って閉じるか。
    var isClosed: Bool
}

/// sRGB の色と不透明度。
nonisolated struct VectorColor: Sendable, Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    /// 乗算していない不透明度 (0…1)。
    var opacity: Float

    /// 作業空間の色 (線形・Display P3・アルファ乗算済み) を、sRGB の 8 ビットへ写す。
    ///
    /// 配る形 (GIF・MP4) と同じ理由で sRGB へ写してから書く ([ADR-0025] 決定 3 の改訂 (2026-10-20))。
    /// 原色の移し替え (``ColorPrimaries``) と伝達関数 (``TransferFunction``) は入口と出口が使うものと
    /// 同じで、**自前の表を持たない**。sRGB の外へ出る色は成分ごとに範囲へ収める。
    ///
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    init(_ color: LinearRGBA) {
        let alpha = color.alpha
        guard alpha.isFinite, alpha > 0 else {
            self.init(red: 0, green: 0, blue: 0, opacity: 0)
            return
        }
        let straight = SIMD3(color.red, color.green, color.blue) / alpha
        let linear = ColorPrimaries.sRGB(fromWorking: straight)
        func byte(_ value: Float) -> UInt8 {
            guard value.isFinite else { return 0 }
            let encoded = TransferFunction.encode(min(max(value, 0), 1))
            return UInt8((min(max(encoded, 0), 1) * 255).rounded())
        }
        self.init(
            red: byte(linear.x), green: byte(linear.y), blue: byte(linear.z),
            opacity: min(alpha, 1))
    }

    /// 書いても見えないか。**不透明度は 1/1000 の桁で書く** (``SVGWriter``) ので、それより薄いものは
    /// `0` と書かれる。数でない不透明度も見えないものに数える。
    var isInvisible: Bool { !(opacity >= 0.0005) }

    init(red: UInt8, green: UInt8, blue: UInt8, opacity: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}

/// 塗り。
nonisolated struct VectorFill: Sendable, Equatable {
    var color: VectorColor
    /// 回り数が奇数の所だけを塗るか (穴のある形・SVG の `fill-rule="evenodd"`)。
    var evenOdd: Bool
}

/// 輪郭。
nonisolated struct VectorStroke: Sendable, Equatable {
    var color: VectorColor
    /// 線の太さ。**変換の拡大率を掛けた値** (画面の道で、太さが変換に従うのと同じ)。
    var width: Float
    var cap: StrokeCap
    var join: StrokeJoin
    /// 破線の長さと間隔 (拡大率を掛けた値)。空なら実線。
    var dash: [Float] = []
}

/// SVG の要素 1 つになる図形。
nonisolated struct VectorFigure: Sendable, Equatable {
    var subpaths: [VectorSubpath]
    var fill: VectorFill?
    var stroke: VectorStroke?
}

/// 書けなかった (あるいは書いたが画面と違う) 図形の種類。**名乗りの単位**である。
nonisolated enum VectorDrop: UInt8, Sendable, CaseIterable {
    case text
    case image
    case retainedShape
    case solid
    case pixels
    case filter
    case particles
    case shader
    case texture
    case gradient
    case blendMode
    case clip
    /// このフレームに掛けた効果 (`effects()`)。出力段の手前に立つ段で、ベクターには効かない。
    case effects
    /// 頂点ごとに塗りの色が違う形。最初の頂点の色で書いた (落としてはいない)。
    case vertexColours
    /// 座標・線の太さ・破線の長さのどれかが、書ける大きさ (約 1e12) を越える図形。画面には描かれるので名乗る。
    /// **原因が種類でなく大きさ**なので、名乗りの文面は他の種類と別の節で、原因を言う。
    /// 数でない座標の図形は画面にも描かれないので、これには数えない (``SVGWriter/Fit``)。
    case tooLarge

    /// 名乗りの文面での呼び名 (英語・単数も複数も同じ)。
    var noun: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .retainedShape: "retained shape"
        case .solid: "3D solid"
        case .pixels: "pixel write"
        case .filter: "filter"
        case .particles: "particles"
        case .shader: "shape with a shader"
        case .texture: "shape with a texture"
        case .gradient: "shape with a gradient fill"
        case .blendMode: "shape with a blend mode other than the normal one"
        case .clip: "shape inside a clip"
        case .effects: "effects() call"
        case .vertexColours: "shape with a different fill colour at each vertex"
        case .tooLarge: "shape"
        }
    }

    /// 落としたのでなく、書いたが画面と違うもの。
    var isWrittenDifferently: Bool { self == .vertexColours }
}
