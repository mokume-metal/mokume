// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

// 製品の原文を読み、**CPU が GPU 可視メモリに触る場所が、待ちの規律の中にあるか**を見る。
//
// ## なぜ要るか
//
// 描き切りは GPU の完了を待たずに返る ([#727](https://github.com/mokume-metal/mokume/issues/727))。
// だから CPU が GPU 可視メモリに触る (書く・GPU の結果を読む) 場所は、触る直前に
// `RenderDevice.settle()` で待たなければならない。触る口は `MTLBuffer.contents()` と
// `MTLTexture.replace(region:…)` の 2 つしかないので、その出現を数えれば規律の適用範囲が
// 機械で分かる。待ち忘れの症状は「絵がたまに乱れる・値がたまに古い」で、再現しないので
// 原文で見る。
//
// ## 規則
//
// > `Sources/` で `.contents()` か `.replace(region` を書けるのは、下の一覧にあるファイルだけ。
// > 一覧の各行は、その場所がなぜ安全かを名乗る。
//
// 新しい場所で触りたくなったら、待ちを置いてから一覧に理由ごと足す。理由を書けない場所は、
// 触る前に待っていないということである。

/// GPU 可視メモリに触る場所が、待ちの規律の一覧に載っているかを原文から見る。
@Suite("GPU 可視メモリに触る場所")
struct GPUMemoryAccessGateTests {
    /// 触ってよい場所と、その理由。
    ///
    /// `settles` は「そのファイル自身が `settle` を呼ぶ」ことを要求する。呼ばない側の理由は
    /// 「作成時だけ書く」か「自前で待つ別の経路の中で書く」のどちらかでなければならない。
    private struct Permit {
        let file: String
        let settles: Bool
        let reason: String
    }

    private static let permits: [Permit] = [
        Permit(
            file: "Drawing/Canvas.swift", settles: true,
            reason: "描き切りの先頭で settle してから頂点・列ごとの値・uniforms を書く。init の書き込みは作成時だけ"),
        Permit(
            file: "Drawing/Canvas+Effects.swift", settles: false,
            reason: "描き切りの中 (settle の後) で効果の値を書く"),
        Permit(
            file: "Drawing/Computation.swift", settles: true,
            reason: "値を書く直前に settle する"),
        Permit(
            file: "Drawing/Particles.swift", settles: true,
            reason: "粒と指定を書く直前に settle する"),
        Permit(
            file: "Rendering/Numbers.swift", settles: true,
            reason: "書く口がすべて settle を通る。読む口 (snapshot) は Canvas.read が settle してから呼ぶ"),
        Permit(
            file: "Rendering/RenderTarget.swift", settles: true,
            reason: "画素を読む直前に settle する"),
        Permit(
            file: "Output/EncodedImage.swift", settles: false,
            reason: "encodeToImage が commitAndWait してから読む"),
        Permit(
            file: "Output/OutputPass.swift", settles: false,
            reason: "encodeToImage が毎回 commitAndWait するので、前の出力段は終わっている"),
        Permit(
            file: "Display/PresentPipeline.swift", settles: false,
            reason: "差し出しの前には必ず描き切りの settle が挟まるので、前の差し出しは終わっている"),
        Permit(
            file: "Text/GlyphAtlas.swift", settles: true,
            reason: "焼く直前に settle する。面の作成時の書き込みは新しい面へ"),
        Permit(
            file: "Image/Image.swift", settles: true,
            reason: "面へ送る直前に settle する"),
    ]

    private static let tokens = [".contents()", ".replace(region"]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ
            .appending(path: "Sources/MokumeCore")
    }

    private func touchingFiles() throws -> [String: String] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(!names.isEmpty, "製品の原文が 1 つも見つからない (\(sourceRoot.path))")
        var touching: [String: String] = [:]
        for name in names {
            let source = try String(contentsOf: sourceRoot.appending(path: name), encoding: .utf8)
            // 引数が改行をまたいで書かれていても数えるよう、空白を畳んでから探す
            let squeezed = source.filter { !$0.isWhitespace }
            if Self.tokens.contains(where: { squeezed.contains($0) }) {
                touching[name] = source
            }
        }
        return touching
    }

    @Test("触る場所はすべて一覧に載っている")
    func everyAccessIsPermitted() throws {
        let touching = try touchingFiles()
        let permitted = Set(Self.permits.map(\.file))
        let unlisted = touching.keys.filter { !permitted.contains($0) }.sorted()
        #expect(
            unlisted.isEmpty,
            """
            GPU 可視メモリに触っているのに、待ちの規律の一覧に無い:

            \(unlisted.map { "Sources/MokumeCore/\($0)" }.joined(separator: "\n"))

            触る直前に gpu.settle() (投げない口では settleQuietly) を置き、
            GPUMemoryAccessGateTests.permits に理由ごと足す。
            """)
    }

    @Test("一覧に載っている場所は、まだ触っていて、名乗ったとおり待っている")
    func everyPermitIsHonest() throws {
        let touching = try touchingFiles()
        for permit in Self.permits {
            guard let source = touching[permit.file] else {
                Issue.record("\(permit.file) はもう GPU 可視メモリに触っていない。一覧から外す")
                continue
            }
            if permit.settles {
                #expect(
                    source.contains("settle"),
                    "\(permit.file) は「settle する」と名乗っているが、settle を呼んでいない")
            }
        }
    }
}
