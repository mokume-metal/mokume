// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing

@testable import MokumeCore

@Suite("画像入力の Metal 変換", .enabled(if: RenderDevice.isAvailable))
@MainActor struct ImageInputTests {
    private let side = 1024

    private func picture(_ value: UInt8 = 127) -> DisplayImage {
        DisplayImage(width: side, height: side, bytes: Array(repeating: value, count: side * side * 4))
    }

    private func canvas(on gpu: RenderDevice) throws -> Canvas {
        try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
    }

    private func texels(_ image: Image, on gpu: RenderDevice) throws -> [SIMD4<Float16>] {
        try gpu.settle()
        var values = [SIMD4<Float16>](repeating: .zero, count: image.width * image.height)
        values.withUnsafeMutableBytes {
            image.texture.getBytes(
                $0.baseAddress!, bytesPerRow: image.width * 8,
                from: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0)
        }
        return values
    }

    @Test("全 256 階調と全アルファの組合せが CPU の規範と半精度で一致する")
    func exactConversion() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var expected = [SIMD4<Float16>](repeating: .zero, count: side * side)
        for index in expected.indices {
            let value = UInt8(index & 255)
            let alphaByte = UInt8((index >> 8) & 255)
            let alpha = Float(alphaByte) / 255
            let channels = [value, 255 - value, value &* 73]
            for c in 0..<3 {
                bytes[index * 4 + c] = channels[c]
                expected[index][c] = Float16(TransferFunction.decode(Float(channels[c]) / 255) * alpha)
            }
            bytes[index * 4 + 3] = alphaByte
            expected[index].w = Float16(alpha)
        }
        image.write(DisplayImage(width: side, height: side, bytes: bytes))
        // 呼び手の配列の再利用が、書いた画像へ後から漏れない。
        bytes[0] = 255
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        #expect(image.displayInput != nil, "CPU の逃げ道だけで検査を通していない")
        #expect(canvas.imageInputPass != nil)
        #expect(try texels(image, on: gpu) == expected)
        let gpuOutput = try canvas.target.encodeForDisplay()
        image.materializePixels()
        #expect(image.pixels == expected)
        image.set(0, 0, image.get(0, 0))
        try canvas.draw {
            canvas.background(.transparent)
            canvas.image(image, 0, 0, 32, 32)
        }
        #expect(try canvas.target.encodeForDisplay() == gpuOutput)
        #expect(gpu.commandFaultCount == 0)
    }

    @Test("少数編集は最後の値を保持し、送信後の編集と CPU 読みも同じ値になる")
    func sparseEditsAndRead() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture())
        let red = LinearRGBA(premultipliedRed: 1, green: -0.25, blue: 0, alpha: 0.5)
        let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        image.set(3, 4, red)
        image.set(3, 4, blue)
        #expect(image.inputPatches.count == 1)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        #expect(!image.inputNeedsDecode)
        image.set(5, 6, red)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        let actual = try texels(image, on: gpu)
        #expect(actual[4 * side + 3] == SIMD4(0, 0, 1, 1))
        #expect(actual[6 * side + 5] == SIMD4(1, -0.25, 0, 0.5))
        #expect(!image.needsUpload)
        _ = image.get(5, 6)
        #expect(image.displayInput == nil)
        #expect(!image.needsUpload, "読むだけで送り直さない")
        #expect(image.pixels == actual)
    }

    @Test("編集上限・fill・再度の write で古い入力や編集を復活させない")
    func transitions() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture())
        for index in 0..<Image.inputPatchLimit {
            image.set(index % side, index / side, .linear(red: 1, green: 0, blue: 0))
        }
        #expect(image.displayInput != nil)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        let edited = try texels(image, on: gpu)
        #expect(edited.prefix(Image.inputPatchLimit).allSatisfy { $0 == SIMD4(1, 0, 0, 1) })
        let capacity = canvas.uploadStorage.capacity
        image.set(0, 4, .linear(red: 0, green: 1, blue: 0))
        #expect(image.displayInput == nil)
        #expect(image.get(0, 4).green == 1)
        #expect(image.get(0, 0).red == 1)
        image.write(picture(255))
        image.set(1, 1, .transparent)
        image.fill(.linear(red: 0, green: 0, blue: 1))
        #expect(image.displayInput == nil)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        #expect(try texels(image, on: gpu).allSatisfy { $0 == SIMD4(0, 0, 1, 1) })
        image.write(picture(255))
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        #expect(try texels(image, on: gpu).allSatisfy { $0 == SIMD4(repeating: 1) })
        #expect(canvas.uploadStorage.capacity == capacity)
        #expect(capacity == side * side * 8)
    }

    @Test("範囲外のアクセス・大きさ違いは遅らせた入力を変えない")
    func invalidOperations() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture())
        let generation = image.uploadGeneration
        #expect(image.get(-1, 0) == .transparent)
        image.set(side, 0, .transparent)
        image.write(DisplayImage(width: 1, height: 1, bytes: [0, 0, 0, 0]))
        #expect(image.displayInput != nil)
        #expect(image.uploadGeneration == generation)
    }

    @Test("GPU 準備が使えなくても少数編集を含む値を CPU から届ける")
    func preparationFallback() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture())
        image.set(0, 0, .linear(red: 1, green: 0, blue: 0))
        canvas.failImageInputForTesting = true
        try canvas.draw { canvas.image(image, 0, 0) }
        #expect(!image.needsUpload)
        #expect(image.displayInput == nil)
        #expect(try texels(image, on: gpu) == image.pixels)
    }

    @Test("積んだ後に投入を捨てても、次の描き切りが入力と編集を届ける")
    func cancelledCommandsAndGeneration() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture(255))
        image.set(0, 0, .transparent)
        image.requestUpload()
        try canvas.frameRing.advance()
        #expect(throws: RenderFailure.self) {
            try gpu.withCommands { commands throws(RenderFailure) in
                _ = try canvas.encodeUploads(into: commands)
                throw .encoderUnavailable
            }
        }
        #expect(image.needsUpload && image.inputNeedsDecode)
        try canvas.draw { canvas.background(.transparent) }
        #expect(!image.needsUpload)
        let actual = try texels(image, on: gpu)
        #expect(actual[0] == .zero && actual[1] == SIMD4(repeating: 1))
        let generation = image.uploadGeneration
        image.write(picture())
        image.markUploaded(through: generation)
        #expect(image.needsUpload && image.inputNeedsDecode)
    }

    @Test("大きすぎる入力の直接送信も待てなければ保留し、再試行できる")
    func directFallbackWait() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture(255))
        canvas.uploadByteLimit = 0
        gpu.failSettleForTesting = .timedOut(seconds: 5)
        try canvas.draw { canvas.image(image, 0, 0) }
        gpu.failSettleForTesting = nil
        #expect(image.needsUpload && image.displayInput != nil)
        try canvas.draw { canvas.background(.transparent) }
        #expect(!image.needsUpload && image.directUploads == 1)
        #expect(try texels(image, on: gpu).allSatisfy { $0 == SIMD4(repeating: 1) })
    }

    @Test("環を回しながら複数画像を送り、別 Canvas からも最終世代を読む")
    func multipleOwnersAndCanvases() throws {
        let gpu = try RenderDevice()
        let first = try canvas(on: gpu)
        let second = try canvas(on: gpu)
        let images = try (0..<3).map { _ in try first.createImage(side, side) }
        let small = try first.createImage(2, 2)
        for frame in 0..<12 {
            let active = frame % 3 + 1
            for index in 0..<active {
                images[index].write(picture(UInt8(frame * 16 + index)))
                images[index].set(index, 0, .linear(red: Float(frame), green: 0, blue: 0))
            }
            let destination = frame.isMultiple(of: 2) ? first : second
            small.fill(.linear(red: Float(frame), green: 0, blue: 0))
            try destination.draw {
                destination.image(small, 0, 0)
                for image in images.prefix(active) { destination.image(image, 0, 0, 32, 32) }
            }
        }
        for (index, image) in images.enumerated() {
            let actual = try texels(image, on: gpu)
            #expect(actual[index].x == 11)
            #expect(actual == image.pixels)
        }
        #expect(gpu.commandFaultCount == 0)
    }

    @Test("配置後の write は描き切り時に反映し、途中の読み取りより前の絵を変えない")
    func placementAndIntermediateFlush() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        try canvas.draw {
            canvas.background(.transparent)
            canvas.image(image, 0, 0, 16, 32)
            image.write(picture(255))
            canvas.loadPixels()
            image.write(picture(0))
            canvas.image(image, 16, 0, 16, 32)
        }
        let output = try canvas.target.encodeForDisplay()
        #expect(output[8, 16] == (255, 255, 255, 255))
        #expect(output[24, 16] == (0, 0, 0, 0))
    }

    @Test("未更新の画像を配置した後の write・set・fill が同じ描き切りへ届く",
          arguments: [2, 1024], ["write", "set", "fill"])
    func cleanPlacementThenEdit(size: Int, action: String) throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(size, size)
        let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        try canvas.draw {
            canvas.image(image, 0, 0, 16, 32)
            canvas.image(image, 16, 0, 16, 32)
            switch action {
            case "write":
                image.write(DisplayImage(
                    width: size, height: size,
                    bytes: Array(repeating: 255, count: size * size * 4)))
            case "set": image.set(0, 0, white)
            default: image.fill(white)
            }
        }
        #expect(try texels(image, on: gpu)[0] == SIMD4(repeating: 1))
        #expect(!image.needsUpload)
        let barriers = canvas.uploadBarriersEncoded
        try canvas.draw { canvas.image(image, 0, 0) }
        #expect(canvas.uploadBarriersEncoded == barriers, "未変更なら転送しない")
        #expect(!image.isQueuedForUpload)
    }

    @Test("GPU 分岐の境界と奇数幅でも最後の画素と編集位置が一致する",
          arguments: [1023, 1024, 1025])
    func boundary(width: Int) throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(width, side + 1)
        image.write(DisplayImage(
            width: width, height: side + 1,
            bytes: Array(repeating: 255, count: width * (side + 1) * 4)))
        image.set(width - 1, side, .transparent)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        let actual = try texels(image, on: gpu)
        #expect(actual.last == .zero)
        #expect(actual.dropLast().allSatisfy { $0 == SIMD4(repeating: 1) })
        #expect((canvas.imageInputPass != nil) == (width * (side + 1) >= Image.metalInputMinimumPixels))
    }

    @Test("少数編集は非有限値と符号付きゼロも CPU の控えと同じビットで届ける")
    func specialPatchValues() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(side, side)
        image.write(picture())
        let value = LinearRGBA(
            premultipliedRed: .infinity, green: -.infinity, blue: -0.0, alpha: .nan)
        image.set(0, 0, value)
        let expected = try #require(image.inputPatches[0])
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        let actual = try texels(image, on: gpu)[0]
        for component in 0..<4 { #expect(actual[component].bitPattern == expected[component].bitPattern) }
    }

    @Test("画像と Canvas を手放しても投入は完了し、常駐の集合へ残り続けない")
    func retirement() throws {
        let gpu = try RenderDevice()
        func submitAndRelease() throws {
            try autoreleasepool {
                let canvas = try canvas(on: gpu)
                let image = try canvas.createImage(side, side)
                image.write(picture())
                image.set(0, 0, .transparent)
                try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
            }
            try gpu.settle()
        }
        try submitAndRelease()
        let settled = gpu.residencySet.allocationCount
        for _ in 0..<8 { try submitAndRelease() }
        #expect(gpu.residencySet.allocationCount == settled)
        #expect(gpu.retiredResourceCount == 0 && gpu.heldResourceCount == 0)
        #expect(gpu.commandFaultCount == 0)
    }

    @Test("小さな入力は追加の GPU 段を作らない")
    func smallInput() throws {
        let gpu = try RenderDevice()
        let canvas = try canvas(on: gpu)
        let image = try canvas.createImage(1, 1)
        image.write(DisplayImage(width: 1, height: 1, bytes: [255, 128, 0, 255]))
        try canvas.draw { canvas.image(image, 0, 0) }
        #expect(canvas.imageInputPass == nil)
        #expect(try texels(image, on: gpu) == image.pixels)
    }
}
