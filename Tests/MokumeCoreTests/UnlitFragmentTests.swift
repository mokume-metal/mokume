// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 光と周囲の枝を外した断片を、どの頂点関数で組むかの検査 ([#1778])。GPU を要しない。
///
/// **絵では見分けられない退行を、ここで捕まえる。** 平面と立体の輪郭で枝を残しても
/// 色は変わらない (枝は必ず偽になる) — 変わるのは速さだけなので、台帳も画素の検査も
/// 黙る。逆に立体の塗りから枝を外すと光も周囲も背景も消えるが、それは光の検査
/// (`LightTests` など) が絵で捕まえる。ここが見るのは前者の側である。
///
/// **見るのは、組み立てが特化に渡す値そのもの** (``ShapePipeline/fragmentConstants(vertexFunctionName:formFlags:)``)。
/// 表 (``ShapePipeline/shapeLit(forVertexFunction:)``) だけを見ていた頃は、組み立てが表を
/// 通さずに `true` を渡しても緑のままだった ([#2293])。
///
/// [#1778]: https://github.com/mokume-metal/mokume/issues/1778
/// [#2293]: https://github.com/mokume-metal/mokume/issues/2293
@Suite("光の枝を外す断片")
struct UnlitFragmentTests {
    /// **平面と立体の輪郭は枝を外す。** どちらも向きを 0 で出し、光も周囲も持たない列。
    @Test func flatAndSolidStrokeDropTheLightingBranches() {
        #expect(ShapePipeline.shapeLit(forVertexFunction: ShapePipeline.flatVertexFunctionName) == false)
        #expect(
            ShapePipeline.shapeLit(forVertexFunction: ShapePipeline.solidStrokeVertexFunctionName)
                == false)
    }

    /// **立体の塗りは枝を残す** — 光・周囲・背景のすべてがこの頂点関数の列を通る。
    @Test func solidFillKeepsTheLightingBranches() {
        #expect(ShapePipeline.shapeLit(forVertexFunction: ShapePipeline.solidVertexFunctionName))
    }

    /// **知らない頂点関数は枝を残す側に倒す。** 外してよいのは「必ず偽」と言える関数だけ
    /// なので、名前を足したときに黙って外れる形にしない。
    @Test func unknownVertexFunctionsKeepTheLightingBranches() {
        #expect(ShapePipeline.shapeLit(forVertexFunction: "someFutureVertexMain"))
    }

    /// **組み立てが特化に渡す値。** 三角形の経路の断片には光の有無だけを、基本図形の断片には
    /// 旗だけを渡す — 読まない値を渡す先は無い。
    @Test func theAssemblyPassesTheLightingDecisionThrough() {
        typealias Constants = ShapePipeline.FragmentConstants
        func constants(_ vertex: String, _ flags: UInt32? = nil) -> Constants {
            ShapePipeline.fragmentConstants(vertexFunctionName: vertex, formFlags: flags)
        }
        #expect(constants(ShapePipeline.flatVertexFunctionName) == Constants(lit: false))
        #expect(constants(ShapePipeline.solidStrokeVertexFunctionName) == Constants(lit: false))
        #expect(constants(ShapePipeline.solidVertexFunctionName) == Constants(lit: true))
        #expect(constants("someFutureVertexMain") == Constants(lit: true))
        // 基本図形の断片は kShapeLitValue を読まない
        let flags = FormInstance.fillsFlag | FormInstance.strokesFlag
        #expect(
            constants(ShapePipeline.flatVertexFunctionName, flags)
                == Constants(formFlags: flags, lit: nil))
    }
}
