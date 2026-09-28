// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite(
    "寸法を変える球の稜線の控え",
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が要る")
)
struct SolidEdgeCacheTests {
    @Test("半径の違いと毎枚の変化で稜線を作り直さない", arguments: [false, true])
    func spheresShareEdgesAcrossRadii(animated: Bool) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 32, height: 32)
        let count = animated ? 10 : 100
        var builds: [Int] = []
        for frame in 0..<10 {
            try canvas.draw {
                canvas.background(0)
                for index in 0..<count {
                    canvas.sphere(20 + Float(index) + (animated ? Float(frame * count) : 0))
                }
            }
            builds.append(canvas.solidEdges.made)
        }
        #expect(builds.first == 1, "同じ detail の球は、初回から1つの稜線を共有する")
        #expect(builds.dropFirst().allSatisfy { $0 == builds[0] }, "2枚目から作り直している: \(builds)")
    }

    @Test("共有した球の点と辺は、その寸法で直接作ったものと一致する")
    func sharedSpheresMatchDirectEdges() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 32, height: 32)
        for detail in [3, 4, 7, 8, 24, 64, 128] {
            let before = canvas.solidEdges.made
            for radius: Float in [1e-30, 1e-20, 0.01, 0.1, 1, 7, 20, 99, 1e5, 1e15, 1e20] {
                let shape = SolidShape.sphere(radius: radius, detail: detail)
                let cached = canvas.solidEdges(of: .mesh(shape), mesh: { shape.make() })
                let direct = SolidEdges(shape.make())
                #expect(cached.points == direct.points, "detail=\(detail), radius=\(radius)")
                #expect(cached.edges.count == direct.edges.count)
                #expect(zip(cached.edges, direct.edges).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })
            }
            #expect(canvas.solidEdges.made - before == 1, "半径ごとに同じ稜線を作っている")
        }
    }

    @Test("潰れる球・計算範囲の端・非一様な寸法は、直接作った稜線を保つ")
    func exceptionalSizesKeepTheirOwnEdges() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 32, height: 32)
        let shapes: [SolidShape] = [
            .sphere(radius: 0, detail: 24),
            .sphere(radius: .leastNonzeroMagnitude, detail: 24),
            .sphere(radius: .leastNormalMagnitude, detail: 24),
            .sphere(radius: 1e-34, detail: 24),
            .sphere(radius: 1e30, detail: 24),
            .sphere(radius: .greatestFiniteMagnitude / 2, detail: 24),
            .ellipsoid(radiusX: 1e-6, radiusY: 1e6, radiusZ: 1, detail: 24),
            .ellipsoid(radiusX: 0, radiusY: 20, radiusZ: 10, detail: 24),
            .box(width: 0, height: 10, depth: 10),
            .cone(radius: 1e-6, height: 1e6, detail: 24),
        ]
        for shape in shapes {
            let cached = canvas.solidEdges(of: .mesh(shape), mesh: { shape.make() })
            let direct = SolidEdges(shape.make())
            #expect(cached.points == direct.points)
            #expect(cached.edges.count == direct.edges.count)
            #expect(zip(cached.edges, direct.edges).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })
        }
        #expect(canvas.solidEdges.count == shapes.count)
    }

}
