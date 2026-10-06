// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// STL のモデルを読む ([#1966](https://github.com/mokume-metal/mokume/issues/1966))。
///
/// 読むのは Model I/O で、ここが見るのはその**結果をどう写すか**と、**断られたときに何を返すか**
/// である。どれも面を作らずに確かめられるので、GPU の無い実行でも走る。面から読む経路は
/// ``ModelLoadingTests`` が見る。
///
/// **検体は Swift の値で持ち、要るときに書き出す** (``ModelFixture``)。リポジトリに `.stl` は
/// 置かない (`scripts/check-no-binaries.sh`)。
@Suite("STL のモデル")
struct STLModelTests {
    /// 四面体。3 面は書かれた向き (外向き)、最後の 1 面は向きを書いていない (`0 0 0`)。
    /// **巻き方は外から見て反時計回り** — STL の約束どおりで、求めた向きも外を指す。
    static let tetrahedron: [ModelFixture.Facet] = [
        .init(normal: SIMD3(0, 0, -1), corners: [SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 0, 0)]),
        .init(normal: SIMD3(0, -1, 0), corners: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)]),
        .init(normal: SIMD3(-1, 0, 0), corners: [SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)]),
        .init(normal: SIMD3(0, 0, 0), corners: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]),
    ]

    /// 中身を一時の置き場へ書き、その道筋で `body` を呼ぶ。置き場は呼び終えたら消す。
    ///
    /// **検査ごとに別の置き場にする** — 並列で走るので、同じ名前を書き合うと取り違える。
    private func withWritten<T>(
        _ contents: Data, as name: String, _ body: (String) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return try body(url.path)
    }

    private func read(_ contents: Data, as name: String = "model.stl") throws -> ModelFile.Parsed {
        try withWritten(contents, as: name) { try ModelFile.load($0) }
    }

    // MARK: - 読める

    @Test("ASCII の STL を読むと、面ごとに 3 点と書かれた向きが並ぶ")
    func asciiFacetsAreRead() throws {
        let parsed = try read(Data(ModelFixture.asciiSTL(Self.tetrahedron).utf8))
        // 点を共有しないので、4 面で 12 点がファイルの順に並ぶ
        #expect(parsed.positions == Self.tetrahedron.flatMap(\.corners))
        // 書かれた 3 面は書かれた向きのまま (3 点とも同じ)
        for (index, facet) in Self.tetrahedron.prefix(3).enumerated() {
            #expect(parsed.normals[index * 3..<index * 3 + 3].allSatisfy { $0 == facet.normal })
        }
        #expect(parsed.hasWrittenNormals)
        // 展開は持たない (囲みの箱の位置に倒れる)
        #expect(parsed.uvs.count == 12)
        #expect(parsed.uvs.allSatisfy { $0 == nil })
        #expect(parsed.skippedLines == 0)
    }

    @Test("バイナリの STL は、同じ面を書いた ASCII の STL と同じに読める")
    func binaryReadsLikeASCII() throws {
        let ascii = try read(Data(ModelFixture.asciiSTL(Self.tetrahedron).utf8))
        // **見出しを `solid` で始める** — そう書き出す道具があり、文字の STL と取り違えやすい
        let binary = try read(ModelFixture.binarySTL(Self.tetrahedron, header: "solid exported"))
        #expect(!binary.positions.isEmpty)
        #expect(binary == ascii)
    }

    @Test("向きの書かれていない面 (0 0 0) は、巻き方から外向きの向きを求める")
    func missingNormalsFollowTheWinding() throws {
        let parsed = try read(Data(ModelFixture.asciiSTL(Self.tetrahedron).utf8))
        // 4 面目は (1,0,0)・(0,1,0)・(0,0,1) を外から反時計回りに巻いた斜めの面
        let outward = normalize(SIMD3<Float>(1, 1, 1))
        #expect(parsed.normals[9..<12].allSatisfy { distance($0, outward) < 1e-6 })
    }

    @Test("どの面にも向きが無ければ、書かれていない扱い (両面) になる")
    func noWrittenNormalsAtAll() throws {
        let parsed = try read(Data(ModelFixture.pyramidSTLText.utf8))
        #expect(parsed.positions.count == 18)
        #expect(parsed.hasWrittenNormals == false)
        #expect(parsed.normals.allSatisfy { abs(length($0) - 1) < 1e-5 })
    }

    @Test("点を共有しない OBJ と、同じ三角形の STL は同じ結果になる", arguments: [true, false])
    func unsharedOBJMatchesSTL(writesNormals: Bool) throws {
        // OBJ も 1 面ごとに自分の点を持たせる。向きを書くなら面ごとに `vn` を 1 つ
        let facets = Self.tetrahedron.map { facet in
            ModelFixture.Facet(
                normal: writesNormals ? normalize(cross(
                    facet.corners[1] - facet.corners[0], facet.corners[2] - facet.corners[0]))
                    : .zero,
                corners: facet.corners)
        }
        var obj: [String] = []
        for (index, facet) in facets.enumerated() {
            for corner in facet.corners { obj.append("v \(corner.x) \(corner.y) \(corner.z)") }
            let first = index * 3 + 1
            if writesNormals {
                obj.append("vn \(facet.normal.x) \(facet.normal.y) \(facet.normal.z)")
                obj.append("f \(first)//\(index + 1) \(first + 1)//\(index + 1) \(first + 2)//\(index + 1)")
            } else {
                obj.append("f \(first) \(first + 1) \(first + 2)")
            }
        }
        let fromOBJ = ModelFile.parse(obj.joined(separator: "\n"))
        let fromSTL = try read(Data(ModelFixture.asciiSTL(facets).utf8))

        #expect(fromSTL.positions == fromOBJ.positions)
        #expect(fromSTL.uvs == fromOBJ.uvs)
        #expect(fromSTL.hasWrittenNormals == fromOBJ.hasWrittenNormals)
        #expect(fromSTL.skippedLines == fromOBJ.skippedLines)
        // 求めた向きは OBJ が Newell の方法・STL が外積で求めるので、最下位の桁だけ違いうる
        #expect(fromSTL.normals.count == fromOBJ.normals.count)
        for (stl, obj) in zip(fromSTL.normals, fromOBJ.normals) {
            #expect(distance(stl, obj) < 1e-5)
        }
    }

    @Test("同じ四角錐の OBJ と STL を整えると、同じ位置・同じ読み取り位置に置かれる", arguments: [60, nil] as [Float?])
    func pyramidMatchesTheOBJ(fitting: Float?) throws {
        let obj = Model.make(
            name: "pyramid.obj", parsed: try ModelFile.load(ModelFixture.pyramid), fitting: fitting)
        let stl = Model.make(
            name: "pyramid.stl", parsed: try ModelFile.load(ModelFixture.pyramidSTL),
            fitting: fitting)

        #expect(stl.triangleCount == obj.triangleCount)
        #expect(stl.size == obj.size)
        #expect(stl.center == obj.center)
        #expect(stl.mesh.points.map(\.position) == obj.mesh.points.map(\.position))
        #expect(stl.mesh.points.map(\.uv) == obj.mesh.points.map(\.uv))
        #expect(stl.hasDerivedNormals == obj.hasDerivedNormals)
        // **向きだけは違う。** STL は点を共有しないので面ごとに平ら (3 点が同じ向き) で、OBJ は
        // 点を共有する面どうしで均される
        let points = stl.mesh.points
        for start in stride(from: 0, to: points.count, by: 3) {
            #expect(points[start].normal == points[start + 1].normal)
            #expect(points[start].normal == points[start + 2].normal)
        }
        #expect(points.map(\.normal) != obj.mesh.points.map(\.normal))
    }

    @Test("拡張子が大文字 (.STL) でも読む")
    func upperCaseExtension() throws {
        let parsed = try read(Data(ModelFixture.pyramidSTLText.utf8), as: "PYRAMID.STL")
        #expect(parsed.positions.count == 18)
    }

    // MARK: - 読めたが面が無い

    @Test("面を 1 つも持たない STL は、投げずに空として読める")
    func emptySolidsAreNotFailures() throws {
        // Model I/O はどちらも「小さすぎる」として断るが、形は整っている
        #expect(try read(Data("solid nothing\nendsolid nothing\n".utf8)) == ModelFile.empty)
        #expect(try read(ModelFixture.binarySTL([])) == ModelFile.empty)
        #expect(ModelFixture.binarySTL([]).count == 84)
    }

    @Test("84 バイトちょうどが面 0 のバイナリで、1 バイト欠ければ読めない・面 1 つなら 134 バイト")
    func binarySizeBoundaries() throws {
        let one = ModelFixture.binarySTL(Array(Self.tetrahedron.prefix(1)))
        #expect(one.count == 134)
        #expect(try read(one).positions == Self.tetrahedron[0].corners)

        let short = ModelFixture.binarySTL([]).dropLast()
        try withWritten(Data(short), as: "short.stl") { path in
            #expect(throws: ModelFailure.unreadable(path: path)) { try ModelFile.load(path) }
        }
    }

    // MARK: - 読めない

    /// 読めないとして投げる中身。
    enum Broken: String, CaseIterable, CustomTestStringConvertible {
        /// 0 バイト。書き出しに失敗したファイルであることが多い
        case empty
        /// STL ではない文字 (84 バイトを超える長さ)
        case notSTL
        /// 最後の面の途中 (`endfacet` の手前) で切れた ASCII の STL
        case cutShort
        /// 大文字の `SOLID` で始まる ASCII の STL (Model I/O はバイナリとして読もうとして断る)
        case upperCaseKeywords

        var testDescription: String { rawValue }

        var contents: Data {
            let whole = ModelFixture.asciiSTL(STLModelTests.tetrahedron)
            switch self {
            case .empty: return Data()
            case .notSTL:
                return Data(String(repeating: "this is not a model at all. ", count: 8).utf8)
            case .cutShort:
                let cut = whole.range(of: "endfacet", options: .backwards)!.lowerBound
                return Data(whole[..<cut].utf8)
            case .upperCaseKeywords: return Data(whole.uppercased().utf8)
            }
        }
    }

    @Test("壊れた STL は、読めないと分かる形で投げる", arguments: Broken.allCases)
    func brokenFilesAreUnreadable(_ broken: Broken) throws {
        try withWritten(broken.contents, as: "broken.stl") { path in
            #expect(throws: ModelFailure.unreadable(path: path)) { try ModelFile.load(path) }
            // 説明は STL として読めないことを名乗る (文字として読めない、ではない)
            let description = ModelFailure.unreadable(path: path).description
            #expect(description.contains("cannot be read as STL"))
        }
    }

    @Test("座標が数でない面は読み飛ばし、面の数として数える")
    func nonFiniteFacetsAreSkipped() throws {
        var facets = Self.tetrahedron
        facets[1].corners[2] = SIMD3(0, .nan, 1)
        facets[2].corners[0] = SIMD3(.infinity, 0, 0)
        let parsed = try read(ModelFixture.binarySTL(facets))
        #expect(parsed.positions == facets[0].corners + facets[3].corners)
        #expect(parsed.skippedLines == 2)
    }

    /// **説明に書いた約束を固定する** (`loadModel` の説明・changelog)。0 にするのは読み手の
    /// Model I/O で、こちらでは拾えない。Model I/O が読み方を変えたら、ここが赤くなって説明の
    /// 直し時を知らせる。
    @Test("ASCII の STL で数として読めない座標は 0 として読まれ、面は残る")
    func asciiNonNumbersBecomeZero() throws {
        // (0, 1, 0) の y を `nan` に、(0, 0, 1) を丸ごと文字にする。どちらも 0 になれば (0, 0, 0)
        var text = ModelFixture.asciiSTL(Self.tetrahedron)
        text = text.replacingOccurrences(of: "vertex 0.0 1.0 0.0", with: "vertex 0.0 nan 0.0")
        text = text.replacingOccurrences(of: "vertex 0.0 0.0 1.0", with: "vertex a b c")
        let parsed = try read(Data(text.utf8))
        let expected = Self.tetrahedron.flatMap(\.corners).map { corner in
            corner == SIMD3(0, 1, 0) || corner == SIMD3(0, 0, 1) ? SIMD3<Float>.zero : corner
        }
        #expect(parsed.positions == expected)
        #expect(parsed.skippedLines == 0)
    }

    // MARK: - 読める形式と説明

    @Test("対応していない形式は、読める形式をすべて名乗って断る")
    func unsupportedNamesEveryReadableFormat() throws {
        try withWritten(Data("ply\n".utf8), as: "points.ply") { path in
            #expect(throws: ModelFailure.unsupported(path: path, extensionName: "ply")) {
                try ModelFile.load(path)
            }
            let description = ModelFailure.unsupported(path: path, extensionName: "ply").description
            for format in ModelFile.Format.allCases {
                #expect(description.contains(format.displayName), "\(format) が説明に無い")
            }
        }
    }

    @Test("一覧に載せた形式は、どれも断られずに読める", arguments: ModelFile.Format.allCases)
    func everyListedFormatIsRead(_ format: ModelFile.Format) throws {
        // **形式を足したら、ここに検体を足すまで組めない** (網羅の switch)
        let sample: String
        switch format {
        case .obj: sample = ModelFixture.pyramidText
        case .stl: sample = ModelFixture.pyramidSTLText
        }
        let parsed = try read(Data(sample.utf8), as: "pyramid.\(format.rawValue)")
        #expect(parsed.positions.count == 18)
    }

    @Test("読めないときの説明は、形式ごとに言い分ける")
    func unreadableDescriptionFollowsTheFormat() {
        #expect(ModelFailure.unreadable(path: "gear.stl").description.contains("as STL"))
        #expect(ModelFailure.unreadable(path: "gear.STL").description.contains("as STL"))
        #expect(ModelFailure.unreadable(path: "head.obj").description.contains("as text"))
    }
}
