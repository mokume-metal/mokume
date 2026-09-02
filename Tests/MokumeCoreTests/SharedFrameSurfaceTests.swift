// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import Testing

@testable import MokumeCore

/// 絵を渡す面の検査 (#703)。
///
/// **読む側は Metal を通さない。** 面の番号から `IOSurfaceLookup` で引き、素のバイトとして
/// 読む — 別のプロセスから読めることを言いたいので、書いた側のテクスチャを覗いては意味が
/// 無い。
enum SharedSurfaceReader {
    /// 番号で引いた面から、1 画素を読む。
    ///
    /// 半精度 4 成分が行ごとに並んでいる。**行の間隔は面が決める** (整列のため幅ぶんより
    /// 広いことがある) ので、必ず面に訊く。
    static func pixel(id: UInt32, x: Int, y: Int) -> (
        red: Float, green: Float, blue: Float, alpha: Float
    )? {
        guard let surface = IOSurfaceLookup(id) else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        guard let base = IOSurfaceGetBaseAddress(surface) as UnsafeMutableRawPointer? else {
            return nil
        }
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let offset = y * bytesPerRow + x * SharedFrameSurface.bytesPerPixel
        let components = base.advanced(by: offset).assumingMemoryBound(to: Float16.self)
        return (
            Float(components[0]), Float(components[1]), Float(components[2]),
            Float(components[3])
        )
    }
}

/// 区画の名乗りだけを見る。**GPU は要らない。**
@Suite("絵を渡す面 (区画の名乗り)")
struct SharedFrameSurfaceFacetTests {
    @Test("区画の名前は一覧から取っている")
    func facetNameComesFromTheList() {
        #expect(StartupReads.viewport.key == "viewport")
        #expect(StartupReads.viewport.origin == .facet)
        // 区画で道具が決めるのはこれだけ — 他が .user であることまで見る
        #expect(StartupReads.viewport.decidedBy == .tool)
        for entry in StartupReads.all where entry.origin == .facet && entry.key != "viewport" {
            #expect(entry.decidedBy == .user, "\(entry.key) が道具の決めるものになっている")
        }
    }
}

@Suite(
    "絵を渡す面",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SharedFrameSurfaceTests {
    /// 区画を 1 つ作って渡す。後片付けまで面倒を見る。
    private func withFacet<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// 与えた色で埋めた絵を、面へ 1 枚差し出す。
    private func written(
        color: LinearRGBA, size: (width: Int, height: Int) = (16, 8), times: Int = 1,
        in directory: URL
    ) throws -> SharedFrameSurface {
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: size.width, height: size.height)
        try source.fill(with: color)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        let shared = try SharedFrameSurface(
            gpu: gpu, width: size.width, height: size.height, at: directory)
        try shared.publishManifest()
        for _ in 0..<times { try shared.write(source, using: presenter) }
        return shared
    }

    @Test("区画が無ければ作らない")
    func withoutFacetItIsNotMade() throws {
        let gpu = try RenderDevice()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        #expect(SharedFrameSurface.makeIfEnabled(gpu: gpu, width: 16, height: 8, at: missing) == nil)
    }

    @Test("面から読んだ画素が、同じ経路で普通のテクスチャへ書いたものと一致する")
    func surfaceMatchesTheOrdinaryDestination() throws {
        let color = LinearRGBA.opaque(red: 0.25, green: 0.5, blue: 0.75)
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: 16, height: 8)
        try source.fill(with: color)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)

        // 行き先が普通のテクスチャのとき
        let ordinary = try RenderTarget(gpu: gpu, width: 16, height: 8)
        try presenter.draw(source, into: ordinary.texture)
        let expected = try ordinary.readPixels()[8, 4]

        // 行き先が共有の面のとき
        let shared = try withFacet { try written(color: color, in: $0) }
        let actual = try #require(SharedSurfaceReader.pixel(id: shared.ids[0], x: 8, y: 4))

        #expect(actual.red == expected.red)
        #expect(actual.green == expected.green)
        #expect(actual.blue == expected.blue)
        #expect(actual.alpha == expected.alpha)
    }

    @Test("面はキャンバスと同じ大きさなので、帯が 1 画素も入らない")
    func noLetterboxIsBakedIn() throws {
        // 2:1 の絵。窓へ出すときは帯が要る比だが、面は同じ大きさなので入らない
        let shared = try withFacet {
            try written(color: .opaque(red: 1, green: 1, blue: 1), size: (32, 16), in: $0)
        }
        for point in [(0, 0), (31, 0), (0, 15), (31, 15), (16, 8)] {
            let pixel = try #require(
                SharedSurfaceReader.pixel(id: shared.ids[0], x: point.0, y: point.1))
            #expect(pixel.red == 1, "\(point) が帯になっている")
        }
    }

    @Test("1.0 を超える明るさが、面の上に残る")
    func valuesAboveTheDisplayRangeSurvive() throws {
        // 8 bit へ落とす断片へ差し替えると、ここが 1.0 に切られて赤くなる
        let shared = try withFacet {
            try written(color: .opaque(red: 4, green: 2, blue: 1.5), in: $0)
        }
        let pixel = try #require(SharedSurfaceReader.pixel(id: shared.ids[0], x: 8, y: 4))
        #expect(pixel.red == 4)
        #expect(pixel.green == 2)
        #expect(pixel.blue == 1.5)
    }

    @Test("面を順に使うので、書いたばかりの面と直前の面が別になる")
    func consecutiveFramesLandOnDifferentSurfaces() throws {
        let shared = try withFacet {
            try written(color: .opaque(red: 0.5, green: 0.5, blue: 0.5), times: 2, in: $0)
        }
        #expect(shared.ids.count == SharedFrameSurface.slotCount)
        #expect(Set(shared.ids).count == shared.ids.count, "面の番号が重複している")
        // **読み手が 1 枚遅れていても書き手が空きを選べる枚数**が要る (2 枚では足りない)
        #expect(SharedFrameSurface.slotCount >= 3, "面が足りない — 読み手の掴んでいる面へ戻る")
        // 2 枚書いたので、いちばん新しいのは 1 枚目とは別の面
        let newest = try #require(SharedFrameSurface.newest(among: shared.ids))
        #expect(newest.frame == 2)
        #expect(newest.id != shared.ids[0], "2 枚続けて同じ面へ書いている")
    }

    @Test("1 枚も書いていない面は、読み手に掴まれない")
    func unwrittenSurfacesAreNotPicked() throws {
        try withFacet { directory in
            let gpu = try RenderDevice()
            let shared = try SharedFrameSurface(gpu: gpu, width: 16, height: 8, at: directory)
            #expect(SharedFrameSurface.newest(among: shared.ids) == nil)
        }
    }

    @Test("枚数は書くたびに 1 つずつ増える")
    func theFrameCountRisesByOne() throws {
        try withFacet { directory in
            let gpu = try RenderDevice()
            let source = try RenderTarget(gpu: gpu, width: 16, height: 8)
            try source.fill(with: .opaque(red: 0, green: 0, blue: 0))
            let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
            let shared = try SharedFrameSurface(gpu: gpu, width: 16, height: 8, at: directory)
            for expected in 1...(SharedFrameSurface.slotCount + 2) {
                try shared.write(source, using: presenter)
                let newest = try #require(SharedFrameSurface.newest(among: shared.ids))
                #expect(newest.frame == expected)
            }
        }
    }

    @Test("面の番号と大きさが区画に置かれる")
    func theManifestCarriesTheIdsAndSize() throws {
        try withFacet { directory in
            let shared = try written(color: .opaque(red: 0, green: 0, blue: 0), in: directory)
            let url = directory.appendingPathComponent(SharedFrameSurface.manifestName)
            let object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(object?["schemaVersion"] as? Int == 1)
            #expect(object?["width"] as? Int == 16)
            #expect(object?["height"] as? Int == 8)
            #expect(object?["ids"] as? [UInt32] == shared.ids)
        }
    }
}
