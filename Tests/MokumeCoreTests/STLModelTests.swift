// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import ModelIO
import Testing
import simd

@testable import MokumeCore

/// STL のモデルを読む ([#1966](https://github.com/mokume-metal/mokume/issues/1966))。
///
/// 読むのは Model I/O で、ここが見るのはその**結果をどう写すか**と、**断られたときに何を返すか**、
/// そして**読める / 読めないの境目が公開の説明のとおりか**である ([#2347](https://github.com/mokume-metal/mokume/issues/2347))。
/// どれも面を作らずに確かめられるので、GPU の無い実行でも走る。面から読む経路は
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

    // MARK: - 境目を試す検体

    /// 1 面だけの文字の STL を、**字下げも小数の桁も付けず**に書いたもの。手で書くとこの大きさ
    /// (105 バイト) になる。`trailing` は末尾の空白の数で、ファイルの大きさだけを動かす
    /// ([#2335](https://github.com/mokume-metal/mokume/issues/2335))。
    static func smallASCII(trailing: Int) -> String {
        "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\n"
            + "endloop\nendfacet\nendsolid t" + String(repeating: " ", count: trailing) + "\n"
    }

    /// ``smallASCII(trailing:)`` の面。
    static let smallFacet = ModelFixture.Facet(
        normal: SIMD3(0, 0, 1), corners: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])

    /// 最初の行だけを `firstLine` に差し替えた、``tetrahedron`` の先頭 3 面の文字の STL。
    static func asciiSTL(firstLine: String) -> String {
        let whole = ModelFixture.asciiSTL(Array(tetrahedron.prefix(3)))
        return firstLine + String(whole.drop(while: { $0 != "\n" }))
    }

    /// `start` で始まる 1 行目を、**改行が 84 バイト目 (添字 83) に来る**長さにそろえる。
    ///
    /// Model I/O は `solid` で始まらない中身をバイナリとして読み、80〜83 バイト目を面の数と
    /// 見る ([#2336](https://github.com/mokume-metal/mokume/issues/2336))。84 バイト目 (面の数の
    /// 最上位) が改行・タブ・CR だと、その値は上限を下回り、文字がバイナリの面として読まれる。
    static func firstLine(_ start: String, length: Int = 83) -> String {
        start + String(repeating: "x", count: length - start.utf8.count)
    }

    /// 84 バイト目 (添字 83) が `byte` であることを確かめて、`text` を返す。そろっていない検体は
    /// 試したいことを試さないので、黙って通さずに止める。
    static func data(_ text: String, byte83 byte: UInt8) -> Data {
        let data = Data(text.utf8)
        precondition(data[83] == byte, "84 バイト目が 0x\(String(byte, radix: 16)) でない")
        return data
    }

    /// Model I/O にファイルを直接読ませた結果。mokume の読み手を通さない。断られたら `nil`。
    private func readByModelIO(_ contents: Data) throws -> (triangles: Int, farthest: Float)? {
        try withWritten(contents, as: "direct.stl") { path in
            var error: NSError?
            let asset = MDLAsset(
                url: URL(fileURLWithPath: path), vertexDescriptor: nil, bufferAllocator: nil,
                preserveTopology: false, error: &error)
            let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
            guard error == nil, !meshes.isEmpty else { return nil }
            var triangles = 0
            var farthest: Float = 0
            for mesh in meshes {
                for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                    triangles += submesh.indexCount / 3
                }
                guard
                    let placed = mesh.vertexAttributeData(
                        forAttributeNamed: MDLVertexAttributePosition, as: .float3)
                else { continue }
                for index in 0..<mesh.vertexCount {
                    let start = (placed.dataStart + index * placed.stride)
                        .assumingMemoryBound(to: Float.self)
                    farthest = max(farthest, abs(start[0]), abs(start[1]), abs(start[2]))
                }
            }
            return (triangles, farthest)
        }
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

    // MARK: - 小さい文字の STL (#2335)

    /// Model I/O は 128 バイトに満たない STL を中身を見ずに断る。**文字の STL は大きさによらず
    /// 読む**と説明しているので、読み手の判定には従わない。
    @Test(
        "手で書いた 1 面の文字の STL は、128 バイトに満たなくても読め、128 バイト以上のものと同じ結果になる",
        arguments: [0, 22, 23, 24])
    func smallASCIIFacetsAreRead(trailing: Int) throws {
        // 105 バイトと 127 バイトが断られていた側、128 バイトと 129 バイトが元から読めた側
        #expect(Self.smallASCII(trailing: trailing).utf8.count == 105 + trailing)
        let parsed = try read(Data(Self.smallASCII(trailing: trailing).utf8))
        #expect(parsed.positions == Self.smallFacet.corners)
        #expect(parsed.normals == Array(repeating: Self.smallFacet.normal, count: 3))
        #expect(parsed.hasWrittenNormals)
        #expect(parsed.skippedLines == 0)
        #expect(parsed == (try read(Data(Self.smallASCII(trailing: 40).utf8))))
    }

    @Test("改行が CRLF の小さい文字の STL も読む")
    func smallCRLFFacetsAreRead() throws {
        let text = Self.smallASCII(trailing: 0).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(text.utf8.count < 128)
        let parsed = try read(Data(text.utf8))
        #expect(parsed.positions == Self.smallFacet.corners)
    }

    /// 埋めた写しは Model I/O に読ませるためだけのもので、読み終えたら消す。**この検査専用の置き場を
    /// 渡す** — 共有の一時の置き場を数えると、並んで走る別の検査が作っている途中の写しを拾う。
    @Test("小さい文字の STL を読んでも、一時の写しは残らない (読めても、断られても)")
    func smallASCIILeavesNoCopyBehind() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stl-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func leftBehind() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        }

        let readable = Data(Self.smallASCII(trailing: 0).utf8)
        _ = try withWritten(readable, as: "small.stl") { path in
            let parsed = try ModelFile.loadSTL(
                URL(fileURLWithPath: path), path: path, scratch: scratch)
            #expect(parsed.positions == Self.smallFacet.corners)
        }
        #expect(try leftBehind().isEmpty)

        // 面の途中で切れていて、読み手が断る経路でも残さない
        let cut = Data("solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\n".utf8)
        _ = try withWritten(cut, as: "cut.stl") { path in
            #expect(throws: ModelFailure.unreadable(path: path)) {
                try ModelFile.loadSTL(URL(fileURLWithPath: path), path: path, scratch: scratch)
            }
        }
        #expect(try leftBehind().isEmpty)
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

    /// 1 行目が 83 文字 (84 バイト目が改行) の面の無い solid。Model I/O は面を見つけられず、80〜83
    /// バイト目を面の数とするバイナリとして読み直し、でたらめな面を返す (#2391)。**名前に `facet` を
    /// 含んでも同じ** — 面の有無を `facet` の語の有無で代用すると、ここを取りこぼす。
    @Test(
        "面を持たない文字の STL は、名前が長く 84 バイト目が改行でも、でたらめな形ではなく空として読める",
        arguments: ["", "facet", "faceted_part_", "endfacets_"], [0, 100])
    func emptySolidWithALongNameIsEmpty(name: String, blankLines: Int) throws {
        let text =
            Self.firstLine("solid " + name) + "\nendsolid x\n"
            + String(repeating: "\n", count: blankLines)
        // 空行が無ければ 128 バイトに満たず (読み手が断る側)、100 行あれば 128 バイト以上 (読み手が
        // バイナリとして読み直す側) — どちらの大きさでも空
        #expect((text.utf8.count < 128) == (blankLines == 0))
        #expect(try read(Self.data(text, byte83: 0x0A)) == ModelFile.empty)
    }

    @Test("面を持たない文字の STL は、頭の 128 バイトに endsolid が入らない長い名前でも空として読める")
    func emptySolidWithAVeryLongNameIsEmpty() throws {
        // 頭の 128 バイトには 1 行目しか入らない。空かどうかは、ファイルの全体を見て決める
        let text = "solid " + String(repeating: "n", count: 200) + "\nendsolid x\n"
        #expect(try read(Data(text.utf8)) == ModelFile.empty)
    }

    @Test("名前に facet・endfacet を含む文字の STL も、面があれば読める", arguments: ["faceted", "endfacets"])
    func keywordsInTheNameDoNotHideFacets(name: String) throws {
        let facets = Array(Self.tetrahedron.prefix(3))
        let parsed = try read(Data(ModelFixture.asciiSTL(facets, name: name).utf8))
        #expect(parsed.positions == facets.flatMap(\.corners))
    }

    /// 面の数 (`endfacet`) は、ファイルを少しずつ読んで数える。**区切りをまたぐ語も拾う**。
    @Test("endfacet の数は、読む区切りの幅によらず同じ", arguments: [1, 2, 3, 5, 7, 8, 9, 16, 1 << 20])
    func endfacetCountDoesNotDependOnTheChunk(chunk: Int) throws {
        // 名前に `endfacet` があっても数えない (行の先頭の語だけ)
        let contents = Data(ModelFixture.asciiSTL(Self.tetrahedron, name: "endfacet endfacet").utf8)
        try withWritten(contents, as: "count.stl") { path in
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let head = try #require(try handle.read(upToCount: 128))
            #expect(ModelFile.endfacetCount(head: head, rest: handle, chunk: chunk) == 4)
        }
    }

    /// **途中で切れたバイナリは、揃っている面だけを読む** (`loadSTL` の説明)。面の数より短い
    /// ファイルと、最後の面の途中で切れたファイルの両方。見出しが `solid` で始まっても同じ。
    @Test(
        "途中で切れたバイナリの STL は、揃っている面だけを読む",
        arguments: ["mokume test", "solid exported"], [0, 20])
    func cutShortBinaryReadsTheCompleteFaces(header: String, partial: Int) throws {
        let whole = ModelFixture.binarySTL(Self.tetrahedron, header: header)
        #expect(whole.count == 84 + 4 * 50)
        // 4 面を宣言し、2 面と、`partial` バイトの 3 面目だけが残る
        let cut = Data(whole.prefix(84 + 2 * 50 + partial))
        let parsed = try read(cut)
        #expect(parsed.positions == Self.tetrahedron.prefix(2).flatMap(\.corners))
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
        /// 128 バイトに満たない、最後の面の途中 (`endfacet` の手前) で切れた ASCII の STL。小さい文字の
        /// STL を読むようにしても、壊れたものまで読んではならない (#2335)
        case cutShortSmall
        /// 最初の面の `facet` の語の途中で切れた、18 バイトの ASCII の STL。面を 1 つも書いていない
        /// ので、読み手に渡さず断る
        case cutBeforeFirstFacetSmall
        /// 同じ切れ方を、末尾の空白で 128 バイトにしたもの。**Model I/O は 128〜132 バイトの、面を読めない
        /// 文字を「面の無い形」として返す** — 渡すと空として読めてしまう
        case cutBeforeFirstFacetAt128
        /// 改行が CR だけの 1 面の文字の STL。Model I/O は CR だけの改行を読めず、面の無い形を返す
        /// — 「読めなかった」を「読めたが面が無い」と取り違えてはならない
        case crOnlySmall
        /// 同じく CR だけの改行の 3 面 (128 バイト以上)
        case crOnlyThreeFacets
        /// 84 バイト目がタブで、`endfacet` が無い (面を書き終えていない) 103 バイトの文字
        case tabAtByte83Small
        /// 頂点が 2 つしかない面の後ろに、正しい面が続く。読み手は後ろの面の頂点を食って、三角形を 1 枚
        /// (形はでたらめ) しか返さない — 面の数 (2) と合わない
        case facetMissingACorner
        /// **ここから下は、84 バイト目 (添字 83) の中身をそろえた文字のファイル** (#2336)。改行だと
        /// Model I/O はバイナリとして読み、80〜83 バイト目を面の数としてでたらめな形を返す
        /// (`indentedOnce` だけは空白で、陰性対照)。前に空白が 2 つ
        case indentedKeyword
        /// 同じ置き方の、大文字の `SOLID`
        case upperCaseKeywordsAtByte83
        /// 同じ置き方の、STL でない文字
        case notSTLAtByte83
        /// 前に空白が 1 つ (84 バイト目は面の字下げの空白) — 陰性対照。Model I/O が面の数が多すぎる
        /// として断るので、前からそのまま投げていた
        case indentedOnce
        /// `solid` の後に改行だけが続く。面も `endsolid` も無く、84 バイト目が改行 (#2391)
        case solidWithoutFacets

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
            case .cutShortSmall:
                let small = STLModelTests.smallASCII(trailing: 0)
                let cut = small.range(of: "endfacet", options: .backwards)!.lowerBound
                return Data(small[..<cut].utf8)
            case .cutBeforeFirstFacetSmall:
                return Data("solid t\nfacet norm".utf8)
            case .cutBeforeFirstFacetAt128:
                return Data(("solid t\nfacet norm" + String(repeating: " ", count: 110)).utf8)
            case .crOnlySmall:
                return Data(STLModelTests.smallASCII(trailing: 0).replacingOccurrences(of: "\n", with: "\r").utf8)
            case .crOnlyThreeFacets:
                let facets = Array(STLModelTests.tetrahedron.prefix(3))
                return Data(ModelFixture.asciiSTL(facets).replacingOccurrences(of: "\n", with: "\r").utf8)
            case .facetMissingACorner:
                let missing = "facet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nendloop\nendfacet\n"
                let good = "facet normal 0 0 1\nouter loop\nvertex 5 5 5\nvertex 6 5 5\nvertex 5 6 5\nendloop\nendfacet\n"
                return Data(("solid t\n" + missing + good + "endsolid t\n").utf8)
            case .tabAtByte83Small:
                return STLModelTests.data(
                    STLModelTests.firstLine("solid ") + "\tfacet normal 0 0 1\n", byte83: 0x09)
            case .indentedKeyword:
                return STLModelTests.data(
                    STLModelTests.asciiSTL(firstLine: STLModelTests.firstLine("  solid ")),
                    byte83: 0x0A)
            case .upperCaseKeywordsAtByte83:
                return STLModelTests.data(
                    STLModelTests.asciiSTL(firstLine: STLModelTests.firstLine("SOLID ")).uppercased(),
                    byte83: 0x0A)
            case .notSTLAtByte83:
                let text = STLModelTests.firstLine("this is not a model at all. ") + "\n"
                    + String(repeating: "this is not a model at all. ", count: 4)
                return STLModelTests.data(text, byte83: 0x0A)
            case .indentedOnce:
                // 1 行目が 82 文字なので、84 バイト目は次の行 (`  facet`) の先頭の空白
                return STLModelTests.data(
                    STLModelTests.asciiSTL(
                        firstLine: STLModelTests.firstLine(" solid ", length: 82)),
                    byte83: 0x20)
            case .solidWithoutFacets:
                return STLModelTests.data("solid" + String(repeating: "\n", count: 200), byte83: 0x0A)
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

    // MARK: - 文字かバイナリかの見分け (#2347)

    /// 文字かバイナリかは、**ファイルの頭の 84 バイト**で決める。バイナリの STL は 80 バイトの
    /// 見出しの後ろに面の数 (4 バイト) を持ち、面の数が約 1,677 万 (2^24) 面に満たなければ最上位の
    /// バイトは 0 である — 文字には出ない値なので、頭の 84 バイトに文字でないバイトが 1 つでもあれば
    /// バイナリと見る。
    /// 頭の 84 バイトの見分けを試す検体と、期待する形。
    enum LayoutSample: String, CaseIterable, CustomTestStringConvertible {
        case empty
        case solidOnly
        case emptySolid
        case indentedKeyword
        case upperCaseKeyword
        case notSTL
        /// 文字でないバイト (NUL) を含み、84 バイトに満たない
        case shortWithNUL
        /// 見出しだけで 1 バイト欠けたバイナリ
        case shortBinary
        case binaryWithoutFaces
        case binaryWithSolidHeader
        case binary

        var testDescription: String { rawValue }

        var contents: Data {
            switch self {
            case .empty: return Data()
            case .solidOnly: return Data("solid".utf8)
            case .emptySolid: return Data("solid t\nendsolid t\n".utf8)
            case .indentedKeyword: return Data("  solid t\n".utf8)
            case .upperCaseKeyword: return Data("SOLID t\n".utf8)
            case .notSTL: return Data(String(repeating: "this is not a model. ", count: 10).utf8)
            case .shortWithNUL: return Data("solid t\u{0}\n".utf8)
            case .shortBinary: return Data(ModelFixture.binarySTL([]).dropLast())
            case .binaryWithoutFaces: return ModelFixture.binarySTL([])
            case .binaryWithSolidHeader:
                return ModelFixture.binarySTL(STLModelTests.tetrahedron, header: "solid exported")
            case .binary: return ModelFixture.binarySTL(STLModelTests.tetrahedron)
            }
        }

        var expected: ModelFile.STLLayout {
            switch self {
            case .solidOnly, .emptySolid: return .text
            case .binaryWithoutFaces, .binaryWithSolidHeader, .binary: return .binary
            case .empty, .indentedKeyword, .upperCaseKeyword, .notSTL, .shortWithNUL, .shortBinary:
                return .unrecognized
            }
        }
    }

    @Test(
        "頭の 84 バイトで、文字の STL・バイナリの STL・どちらでもないものを見分ける",
        arguments: LayoutSample.allCases)
    func layoutFollowsTheFirst84Bytes(_ sample: LayoutSample) {
        #expect(ModelFile.stlLayout(of: sample.contents) == sample.expected)
    }

    // MARK: - Model I/O の判定 (説明が頼る事実)

    // **次の 4 本は、読み手の Model I/O の挙動を固定する。** 説明 (`loadSTL`・`loadModel`) とここまでの
    // 検査は、この挙動を前提に境目を決めている。Model I/O が変わったら、ここが赤くなって、説明と
    // `loadSTL` の見分け方の直し時を知らせる (`asciiNonNumbersBecomeZero` と同じ役)。

    @Test("Model I/O は 128 バイトに満たない STL を、中身を見ずに断る")
    func modelIOTurnsDownFilesUnder128Bytes() throws {
        #expect(try readByModelIO(Data(Self.smallASCII(trailing: 22).utf8)) == nil)  // 127 バイト
        #expect(try readByModelIO(Data(Self.smallASCII(trailing: 23).utf8))?.triangles == 1)  // 128
        #expect(ModelFile.smallestSTLModelIOReads == 128)
    }

    @Test("Model I/O は solid で始まらない文字を、84 バイト目が改行ならバイナリとして読み、でたらめな形を返す")
    func modelIOReadsTextAsBinary() throws {
        let read = try #require(try readByModelIO(Broken.indentedKeyword.contents))
        #expect(read.triangles > 0)
        #expect(read.farthest > 1e30)
        // 84 バイト目が空白なら、面の数が多すぎるとして断る
        #expect(try readByModelIO(Broken.indentedOnce.contents) == nil)
    }

    @Test("Model I/O は、読めない文字を面の無い形で返し、面の無い solid をバイナリとして読み直す")
    func modelIOReturnsAnEmptyShapeForUnreadableText() throws {
        func padded(_ text: String, to size: Int) -> Data {
            Data((text + String(repeating: " ", count: max(0, size - text.utf8.count))).utf8)
        }
        let small = Self.smallASCII(trailing: 0)
        // 改行が CR だけ・改行の無い・`endloop` と `endfacet` を同じ行に並べた文字は、面を書いていても
        // 読めない。CR と改行の無い文字は面が 0 の形が返り、並べたものは断る
        let crOnly = small.replacingOccurrences(of: "\n", with: "\r")
        #expect(try readByModelIO(padded(crOnly, to: 256))?.triangles == 0)
        #expect(try readByModelIO(padded(small.replacingOccurrences(of: "\n", with: " "), to: 256))?.triangles == 0)
        #expect(try readByModelIO(padded(small.replacingOccurrences(of: "endloop\nendfacet", with: "endloop endfacet"), to: 256)) == nil)
        // 面を読めない文字は、128〜132 バイトでは断られずに面の無い形が返り、133 バイトから断られる
        let cut = "solid t\nfacet norm"
        #expect(try readByModelIO(padded(cut, to: 128))?.triangles == 0)
        #expect(try readByModelIO(padded(cut, to: 132))?.triangles == 0)
        #expect(try readByModelIO(padded(cut, to: 133)) == nil)
        // 面を 1 つも読まないまま endsolid まで読み切った文字は、バイナリとして読み直される
        let facetless = try #require(try readByModelIO(Broken.solidWithoutFacets.contents))
        #expect(facetless.triangles > 0)
        // 面の途中で切れた文字は、読み直されずに断られる
        let cutInFacet = Self.firstLine("solid ") + "\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\n"
        #expect(try readByModelIO(Self.data(cutInFacet + String(repeating: " ", count: 100), byte83: 0x0A)) == nil)
    }

    @Test("Model I/O はバイナリの面の数が 238,609,294 までなら、揃っている分を読み、超えると断る")
    func modelIOFaceCountLimit() throws {
        func declaring(_ count: UInt32) -> Data {
            var data = ModelFixture.binarySTL(Array(Self.tetrahedron.prefix(3)))
            data.replaceSubrange(80..<84, with: withUnsafeBytes(of: count.littleEndian) { Array($0) })
            return data
        }
        // 2^32 ÷ 18 の切り捨て。2^28 (268,435,456) より小さい
        #expect(try readByModelIO(declaring(238_609_294))?.triangles == 3)
        #expect(try readByModelIO(declaring(238_609_295)) == nil)
        #expect(try readByModelIO(declaring(1 << 28)) == nil)
    }
}
