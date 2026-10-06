// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 資材の名前を場所へ解く公開の口 (#1978)。探す並びは ``loadImage(_:)`` と同じものを使う。
/// 走っているスケッチも GPU も要らない。
@Suite("資材の場所")
struct AssetURLTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    @Test("在るファイルは、その場所を返す")
    func existingFileIsFound() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-asset-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Bare().assetURL(url.path) == url)
    }

    @Test("無ければ、loadImage と同じ並びの探した場所を添えて投げる")
    func missingFileNamesWhereItLooked() {
        let name = "no-such-asset-\(UUID().uuidString).wav"
        #expect(
            throws: AssetFailure.notFound(
                path: name, searched: ImageFile.candidates(for: name).map(\.path))
        ) {
            try Bare().assetURL(name)
        }
        let message = AssetFailure.notFound(path: name, searched: ["/a/\(name)"]).description
        #expect(message.contains("Looked in:"))
        #expect(message.contains("/a/\(name)"))
    }
}
