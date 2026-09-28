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
/// [#1778]: https://github.com/mokume-metal/mokume/issues/1778
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
}
