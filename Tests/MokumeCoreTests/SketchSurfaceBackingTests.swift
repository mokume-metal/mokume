// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Metal
import Testing

@testable import MokumeCore

/// 絵の面が作る層の、1 枚目の前の見え方 ([#2876](https://github.com/mokume-metal/mokume/issues/2876))。
///
/// **層を作る所 1 か所で塗る。** 絵の面 (``SketchSurface``) を作るのは直に走らせる窓と道具の窓の
/// 2 か所だけで、どちらも `makeBackingLayer` を通る。起こし方ごとに塗ると、配る形と確かめる形で
/// 1 枚目までの見え方が食い違う (ADR-0032 決定 6 の追補)。
@Suite("絵の面の層")
@MainActor
struct SketchSurfaceBackingTests {
    /// 不透明な黒か。成分 (最後の 1 つは不透明度) の色の部分がすべて 0 で、不透明度が 1。
    static func isOpaqueBlack(_ color: CGColor) -> Bool {
        guard let components = color.components, components.count >= 2 else { return false }
        return color.alpha == 1 && components.dropLast().allSatisfy { $0 == 0 }
    }

    @Test(
        "層は、一度も present していなくても不透明な黒で塗られている",
        .enabled(if: RenderDevice.isAvailable, "面を作るのに Metal の装置が要る"))
    func theBackingLayerStartsBlack() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 16, height: 16), device: device,
            input: InputState(), canvasSize: (16, 16))
        surface.wantsLayer = true
        let color = try #require(surface.metalLayer?.backgroundColor)
        #expect(Self.isOpaqueBlack(color), "層の背景が不透明な黒でない: \(color)")
    }
}
