// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 描いた絵を外へ出す経路の検査。GPU を要する。
@Suite(
    "画像の書き出し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageOutputTests {
    /// 検査のあいだだけ使う一時ディレクトリ。
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mokume-image-output-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("同じ絵を 2 回書き出すと、内容が完全に一致する")
    func writingTheSameFrameTwiceProducesIdenticalBytes() throws {
        try withTemporaryDirectory { directory in
            var digests: [String] = []
            for attempt in 0..<2 {
                // 走らせるたびに土台から作り直す。同じ器を使い回して一致しても
                // 「2 回走らせて再現する」ことの証明にならない。
                let gpu = try RenderDevice()
                let target = try RenderTarget(gpu: gpu, width: 32, height: 16)
                try target.fill(with: .linear(red: 0.2, green: 0.4, blue: 0.6))

                let url = directory.appendingPathComponent("frame-\(attempt).png")
                try target.writePNG(to: url)
                digests.append(try digest(of: url))
            }
            #expect(digests[0] == digests[1])
        }
    }

    @Test("書き出しから返った時点で、ファイルができている")
    func writeReturnsOnlyAfterTheFileExists() throws {
        try withTemporaryDirectory { directory in
            let gpu = try RenderDevice()
            let target = try RenderTarget(gpu: gpu, width: 4, height: 4)
            try target.fill(with: .linear(red: 1, green: 1, blue: 1))

            let url = directory.appendingPathComponent("frame.png")
            try target.writePNG(to: url)

            // 「書き始めた」だけで返る形だと、ここが偽になる
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try Data(contentsOf: url).count > 0)
        }
    }

    @Test("塗った線形の色が、伝達関数を経た 8 bit の値で出る")
    func linearFillLandsOnTheExpectedByteValues() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 4, height: 4)
        try target.fill(with: .linear(red: 0.5, green: 1, blue: 0))

        let image = try target.encodeForDisplay()
        #expect(image[0, 0] == (188, 255, 0, 255))
    }

    @Test("表示できる範囲を超えた明るさは、書き出しで端へ寄る")
    func brightnessBeyondTheRangeIsClampedOnTheWayOut() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 2, height: 2)
        try target.fill(with: .linear(red: 4, green: 0.5, blue: 0))

        // 描画先には 4.0 のまま残っているが (ADR-0011 決定 2)、
        // 出力段で標準レンジへ収まる (同 決定 5 の既定)
        #expect(try target.readPixels()[0, 0].red == 4)
        #expect(try target.encodeForDisplay()[0, 0] == (255, 188, 0, 255))
    }
}
