// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

// 製品の原文を読み、**CPU が GPU 可視メモリに触る場所が、待ちの規律の中にあるか**を見る。
//
// ## なぜ要るか
//
// 描き切りは GPU の完了を待たずに返る ([#727](https://github.com/mokume-metal/mokume/issues/727))。
// だから CPU が GPU 可視メモリに触る (書く・GPU の結果を読む) 場所は、触る直前に**待って
// いなければならない**。触る口は `MTLBuffer.contents()` と `MTLTexture.replace(region:…)` の
// 2 つしかないので、その出現を数えれば規律の適用範囲が機械で分かる。待ち忘れの症状は
// 「絵がたまに乱れる・値がたまに古い」で、再現しないので原文で見る。
//
// ## 待ち方は 2 通りある
//
// `RenderDevice.settle()` は**投入済みの全部**を待つ。フレームごとに書く置き場は
// [#754](https://github.com/mokume-metal/mokume/issues/754) で環 (`FrameRing`) に載り、
// 待つ範囲が「そのスロットを読む投入 1 本」へ縮んだ。**どちらで待っているかを一覧が
// 名乗る** — 名乗りを `settles` の真偽 1 つで表していた頃は、`settle` という語が原文に
// あるだけで honest と判定されてしまい、`Canvas.swift` が置いた描き場所を描き切らせる
// 別物 (`settlePlacersBeforeChange`) で緑になれた。
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
    /// 触る場所が名乗れる待ち方。
    private enum Discipline {
        /// 触る直前に ``RenderDevice/settle()`` で**投入済みの全部**を待つ。
        case settles
        /// フレームごとに書く置き場の環に載せ、**そのスロットを読む投入**だけを待つ。
        case ring
        /// 自分では待たない。**呼ぶ側の経路が待っている**ことが理由に書かれている。
        case waitedElsewhere

        /// 名乗りが本当かを原文から見るための語。無ければ見ない。
        var evidence: String? {
            switch self {
            case .settles: "settle"
            case .ring: "FrameRing"
            case .waitedElsewhere: nil
            }
        }
    }

    /// 触ってよい場所と、その理由。
    ///
    /// `discipline` は原文に現れる語で裏を取る (``Discipline/evidence``)。裏の取れない
    /// `waitedElsewhere` の理由は「作成時だけ書く」か「自前で待つ別の経路の中で書く」の
    /// どちらかでなければならない。
    private struct Permit {
        let file: String
        let discipline: Discipline
        let reason: String
    }

    private static let permits: [Permit] = [
        Permit(
            file: "Drawing/Canvas.swift", discipline: .ring,
            reason: "描き切りの先頭で環を 1 つ進め、そのスロットを読む投入だけを待ってから頂点・列ごとの値・uniforms を書く (#754)。init の書き込みは作成時だけ"),
        Permit(
            file: "Drawing/Canvas+Effects.swift", discipline: .waitedElsewhere,
            reason: "描き切りの中 (環を進めた後) で効果の値を書く。書き先は Canvas と同じ環に載った置き場"),
        Permit(
            file: "Drawing/Computation.swift", discipline: .settles,
            reason: "値を書く直前に settle する"),
        Permit(
            file: "Drawing/Particles.swift", discipline: .settles,
            reason: "粒と指定を書く直前に settle する"),
        Permit(
            file: "Rendering/Numbers.swift", discipline: .settles,
            reason: "書く口がすべて settle を通る。読む口 (snapshot) は Canvas.read が settle してから呼ぶ"),
        Permit(
            file: "Rendering/RenderTarget.swift", discipline: .settles,
            reason: "画素の写しを読む直前に settle する (写しへの読み戻しを積んだときは、その完了まで)"),
        Permit(
            file: "Output/EncodedImage.swift", discipline: .waitedElsewhere,
            reason: "encodeToImage が commitAndWait してから読む"),
        Permit(
            file: "Output/OutputPass.swift", discipline: .waitedElsewhere,
            reason: "encodeToImage が毎回 commitAndWait するので、前の出力段は終わっている"),
        Permit(
            file: "Display/PresentPipeline.swift", discipline: .ring,
            reason: "差し出しごとに自分の環を 1 つ進める。描き切りが全完了を待たなくなった時点で、前の差し出しが終わっている保証は他に無い (#754)"),
        Permit(
            file: "Text/GlyphAtlas.swift", discipline: .settles,
            reason: "焼く直前に settle する。面の作成時の書き込みは新しい面へ"),
        Permit(
            file: "Image/Image.swift", discipline: .settles,
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

            触る直前に待ちを置き (投入済みの全部なら gpu.settle() / 投げない口では
            settleQuietly、フレームごとに書く置き場なら FrameRing に載せる)、
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
            guard let evidence = permit.discipline.evidence else { continue }
            #expect(
                source.contains(evidence),
                "\(permit.file) は \(permit.discipline) と名乗っているが、原文に \(evidence) が無い")
        }
    }
}
