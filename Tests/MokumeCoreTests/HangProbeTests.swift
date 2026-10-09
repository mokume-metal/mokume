// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// #2251 の切り分け用 (使い捨て・merge しない)。MOKUME_HANG_PROBE の名前の 1 通りだけを描く

import Foundation
import Testing
import simd

@testable import MokumeCore

@Suite("hang の切り分け", .enabled(if: RenderDevice.isAvailable && ProcessInfo.processInfo.environment["MOKUME_HANG_PROBE"] != nil))
struct HangProbeTests {
    @Test("1 通りを描く")
    func probe() throws {
        let name = ProcessInfo.processInfo.environment["MOKUME_HANG_PROBE"] ?? ""
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        let passThrough = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let parts = Set(name.split(separator: "-").map(String.init))
        for _ in 0..<10 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                if parts.contains("cpu") { canvas.shader(passThrough) }
                if parts.contains("fill") { canvas.fill(.linear(red: 1, green: 0, blue: 0)) } else { canvas.noFill() }
                if parts.contains("stroke") {
                    canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                    canvas.strokeWeight(3)
                } else {
                    canvas.noStroke()
                }
                canvas.translate(100, 100, 0)
                canvas.rotateX(0.45)
                canvas.rotateY(0.7)
                if parts.contains("stretched") { canvas.scale(1.2, 0.8, 1.1) }
                if parts.contains("ellipsoid") { canvas.ellipsoid(55, 27, 55, detail: 64) }
                if parts.contains("sphere") { canvas.sphere(55) }
                if parts.contains("torus") { canvas.torus(55, 16, detail: 128) }
            }
            _ = try canvas.target.encodeForDisplay()
        }
    }
}
