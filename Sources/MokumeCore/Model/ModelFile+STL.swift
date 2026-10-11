// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import ModelIO
import simd

/// STL を読む。**読むのは Model I/O に任せる** ([#1966])。
///
/// STL は形だけの形式 (三角形と面の向き) なので、「形と展開だけを読み、材質は読まない」
/// という約束 (``ModelFile``) のまま足せる。3D プリンタ向けに配られる部品の多くがこの形式である。
///
/// ## Model I/O が返すもの (macOS 27 で確かめた)
///
/// - 文字の STL もバイナリの STL も読む。面ごとに 3 点を持ち、**点を共有しない**
/// - 面の向き (`facet normal`) は書かれた値のまま返す。`0 0 0` も 0 のまま
/// - 縦軸の約束は持たない (`upAxis` は常に y)。3D プリンタ向けの STL は z を上に書くことが多い
/// - 改行が CRLF でも読む。途中で切れたバイナリは、揃っている面だけを読む。文字の STL は、
///   面の途中で切れていれば断り、面の境 (`endfacet` の後) で切れていれば `endsolid` が無くても
///   揃った面を読む
/// - **数として読めない座標は、文字の STL では黙って 0 になる** (`nan`・`a` など)。バイナリの
///   NaN・無限はそのまま返る
///
/// ## Model I/O の境目は、公開の説明と食い違う
///
/// 読めない STL は ``ModelFailure/unreadable(path:)`` を投げ、読めるものを投げない、というのが
/// 公開の説明 (``Sketch/loadModel(_:normalize:)``) の約束である。Model I/O の断り方は、中身ではなく
/// 大きさと頭の判定で決まるので、そのまま従うと次の 3 点で約束が破れる ([#2347])。
///
/// - **128 バイトに満たない STL は、中身を見ずに断る** ([#2335])。面を 1 つ持つバイナリは 134 バイト
///   なので当たらないが、字下げせずに手で書いた 1 面の文字の STL は 100 バイト前後で当たる。
///   **128〜133 バイトは別の癖を持ち、中身によらず「面の無い形」を返す** (面を持てない大きさの
///   バイナリとして読む) — 壊れた文字の STL も、128 バイトまで埋めるだけでは空として読めてしまう
/// - **`solid` で始まらない中身は、文字でもバイナリとして読む** ([#2336])。80〜83 バイト目の 4 バイトを
///   面の数と見て、**238,609,294 (2^32 ÷ 18 の切り捨て。2^28 = 268,435,456 より小さい) 以下ならファイルに
///   揃っている分の面を読み、超えれば断る**。文字のファイルは 84 バイト目が面の数の最上位になり、
///   それが改行・タブ・CR (0x09・0x0A・0x0D) だと値が上限を下回って、文字がでたらめな座標 (1e34 級)
///   の面として返る。84 バイト目が空白や文字なら、面の数が上限を超えて断る
/// - **`solid` で始まる文字でも、面を 1 つも読めなければ、同じバイナリの道へ落ちる。** 面の無い
///   STL の 1 行目が 83 文字で 84 バイト目が改行なら、でたらめな面が返る
///
/// ## mokume が見分けて扱う範囲
///
/// 境目を Model I/O の判定に任せず、**渡す前に頭の 84 バイトで文字かバイナリかを自分で見分ける**
/// (``stlLayout(of:)``)。バイナリは 80 バイトの見出しの後ろに面の数を 4 バイトで持ち、2^24 面
/// (約 1,677 万面。800 MB を超える) に満たなければ最上位のバイトは 0 である。文字には出ない値なので、
/// 頭の 84 バイトに文字でないバイト (NUL・制御文字) が 1 つでもあればバイナリ、すべて文字なら
/// 文字の STL か STL でない文字と見る。
///
/// - **頭がすべて文字で、小文字の `solid` で始まらない** (大文字の `SOLID`・前に空白・STL でない
///   文字) → Model I/O へ渡さず、読めないとして返す
/// - **小文字の `solid` で始まる文字で、`facet` が 1 つも無い** → 渡さず、面の無い STL
///   (``isEmptySTL(_:)``) なら空、そうでなければ読めないとして返す
/// - **同じく `facet` があり、128 バイト以上** → Model I/O に読ませる
/// - **同じく `facet` があり、128 バイトに満たない** → 末尾を空白で埋めた一時の写しを作り、
///   Model I/O に読ませる (``smallestSTLModelIOReads``)。読み手は変えない — 自前で読むと、
///   数でない座標が 0 になるといった読み手の癖が、128 バイトの前後で変わる。埋める大きさは、128 未満の
///   断りと 128〜133 の癖の両方から離す。写しは読み終えたら消す
/// - **頭に文字でないバイトがある** (バイナリ。見出しが `solid` で始まってもよい) → 128 バイト以上は
///   Model I/O に読ませる。128 バイトに満たないものは、Model I/O が必ず断る (面を持てない) ので渡さず、
///   84 バイトの面の無いものだけ空、ほかは読めないとして返す
///
/// 上の 3 つの境目 (128 バイト・面の数の上限・文字をバイナリとして読むこと) は読み手の挙動で、
/// `STLModelTests` が固定している。読み手が変わったら、そこが赤くなって、この節の直し時を知らせる。
///
/// [#1966]: https://github.com/mokume-metal/mokume/issues/1966
/// [#2335]: https://github.com/mokume-metal/mokume/issues/2335
/// [#2336]: https://github.com/mokume-metal/mokume/issues/2336
/// [#2347]: https://github.com/mokume-metal/mokume/issues/2347
nonisolated extension ModelFile {
    /// STL を読む。
    ///
    /// **面の向き**: 書かれた向き (有限で長さが 0 でない) はそのまま使う — OBJ の `vn` と同じ扱い
    /// (``Parsed/hasWrittenNormals``)。`0 0 0` の面は巻き方から求め、OBJ で向きを求めた形と同じく
    /// 両面として扱う。**点を共有しないので、どちらも面ごとに平らに光る** — OBJ で向きを書かない
    /// 形は、点を共有する面どうしで向きが均される。
    ///
    /// **座標が数でない面は読み飛ばし、面の数として数える** (``Parsed/skippedLines``)。残すと
    /// 囲みの箱も整え方も壊れる。
    ///
    /// **面の無い STL は投げずに空を返す。** Model I/O はこれも読めないとして返すか、バイナリとして
    /// 読んででたらめな面を返すが、「読めなかった」と「読めたが面が無い」は別である
    /// (``ModelFailure``)。見分けるのは、Model I/O へ渡す前の面の無い文字・小さいバイナリと、
    /// Model I/O が断ったときである (``isEmptySTL(_:)``)。
    ///
    /// - Parameter scratch: 小さい文字の STL を埋めた写しを置く場所。呼ぶ側が差し替えるのは検査だけ。
    static func loadSTL(
        _ url: URL, path: String, scratch: URL = FileManager.default.temporaryDirectory
    ) throws(ModelFailure) -> Parsed {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw .unreadable(path: path)
        }
        switch stlLayout(of: data) {
        case .unrecognized:
            throw .unreadable(path: path)
        case .binary:
            // 128 バイトに満たないバイナリは、読み手が必ず断る (面を持てない) ので渡さない
            if data.count >= smallestSTLModelIOReads, let parsed = askModelIO(url) { return parsed }
            return try emptyOrUnreadable(data, path: path)
        case .text:
            // 面が 1 つも無い文字は、読み手に渡すとバイナリとして読まれうる
            guard data.range(of: Data("facet".utf8)) != nil else {
                return try emptyOrUnreadable(data, path: path)
            }
            let parsed =
                data.count >= smallestSTLModelIOReads
                ? askModelIO(url) : askModelIO(paddedCopyOf: data, in: scratch)
            if let parsed { return parsed }
            return try emptyOrUnreadable(data, path: path)
        }
    }

    /// Model I/O が断らない STL の最小の大きさ (バイト)。**これに満たない STL は中身を見ずに断る。**
    static let smallestSTLModelIOReads = 128

    /// 小さい文字の STL を埋めて渡すときの大きさ。128 に近いと、128〜133 バイトの癖 (読めない文字も
    /// 「面の無い形」として返す) に掛かるので、面を 1 つ持てるバイナリの大きさ (134) よりも離す。
    private static let paddedSTLSize = 256

    /// 頭の 84 バイトから見分けた、STL の形。
    enum STLLayout: Sendable, Equatable {
        /// 文字の STL (小文字の `solid` で始まり、頭がすべて文字)。
        case text
        /// バイナリの STL (頭に文字でないバイトがあり、見出しと面の数の 84 バイトが揃っている)。
        case binary
        /// どちらでもない (空・前に空白のある文字・大文字の `SOLID`・STL でない文字・84 バイトに
        /// 満たない文字でないバイトを含むもの)。
        case unrecognized
    }

    /// 頭の 84 バイトで、文字の STL かバイナリの STL かを見分ける。
    ///
    /// 文字として許すのは、印字できる文字 (0x20〜0x7E と 0x80 以上 — UTF-8 の名前を含む)・タブ・LF・CR
    /// だけにする。**絞っておくほうが安全な側に倒れる** — 文字と見なさなければ読み手の判定に任せる
    /// (これまでと同じ) だけで、文字と見なすと渡さずに断る。
    static func stlLayout(of data: Data) -> STLLayout {
        let head = data.prefix(84)
        if head.allSatisfy(isTextByte) {
            return head.starts(with: "solid".utf8) ? .text : .unrecognized
        }
        return data.count >= 84 ? .binary : .unrecognized
    }

    private static func isTextByte(_ byte: UInt8) -> Bool {
        (byte >= 0x20 && byte != 0x7F) || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// 面が無い STL なら空、そうでなければ読めないとして返す。
    private static func emptyOrUnreadable(_ data: Data, path: String) throws(ModelFailure) -> Parsed {
        guard isEmptySTL(data) else { throw .unreadable(path: path) }
        return empty
    }

    /// Model I/O にファイルを読ませる。断られたら `nil`。
    private static func askModelIO(_ url: URL) -> Parsed? {
        var error: NSError?
        let asset = MDLAsset(
            url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false,
            error: &error)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard error == nil, !meshes.isEmpty else { return nil }
        return triangles(of: meshes)
    }

    /// 小さい文字の STL を、末尾を空白で ``paddedSTLSize`` まで埋めた写しにして、Model I/O に読ませる。
    ///
    /// 読み手はファイルの道筋からしか読めないので、一時の写しを書く。**写しは読み終えたら、読めても
    /// 断られても消す。** 写しを書けなければ (一時の置き場が書けない) 断られたのと同じに `nil` を返す。
    private static func askModelIO(paddedCopyOf data: Data, in scratch: URL) -> Parsed? {
        var padded = data
        padded.append(contentsOf: repeatElement(UInt8(ascii: " "), count: paddedSTLSize - data.count))
        let directory = scratch.appendingPathComponent(
            "mokume-stl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("model.stl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try padded.write(to: copy)
        } catch {
            return nil
        }
        return askModelIO(copy)
    }

    /// 面を 1 つも持たない、形の整った STL か。
    ///
    /// バイナリは 80 バイトの見出しと面の数 (0) だけの 84 バイト、文字は `solid` の行と
    /// `endsolid` の行だけ。**0 バイトは含めない** — どちらの形にもなっておらず、書き出しに
    /// 失敗したファイルであることが多い。
    static func isEmptySTL(_ data: Data) -> Bool {
        if data.count == 84, data[data.startIndex + 80..<data.endIndex].allSatisfy({ $0 == 0 }) {
            return true
        }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.count == 2 && lines[0].hasPrefix("solid") && lines[1].hasPrefix("endsolid")
    }

    /// Model I/O の形から、三角形の並びを写す。
    private static func triangles(of meshes: [MDLMesh]) -> Parsed {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var hasWrittenNormals = false
        var skipped = 0

        for mesh in meshes {
            guard
                let placed = mesh.vertexAttributeData(
                    forAttributeNamed: MDLVertexAttributePosition, as: .float3)
            else { continue }
            let facing = mesh.vertexAttributeData(
                forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for submesh in submeshes where submesh.geometryType == .triangles {
                // **番号の置き場も、その写しも、読み終わるまで手放さない。** 型を変えた番号の
                // 置き場は新しく作られ、写し (`map`) はそれを持ち続けない — 一時の値のまま
                // 写すと、指した先がすぐに消えて番号がでたらめになる
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                withExtendedLifetime((placed, facing, buffer, map)) {
                    let indices = UnsafeBufferPointer(
                        start: map.bytes.assumingMemoryBound(to: UInt32.self),
                        count: submesh.indexCount)
                    // 3 つに満たない余りは面にならない
                    for start in stride(from: 0, to: indices.count - 2, by: 3) {
                        let corners = (0..<3).map { Int(indices[start + $0]) }
                        guard corners.allSatisfy({ $0 < mesh.vertexCount }) else {
                            skipped += 1
                            continue
                        }
                        let points = corners.map { vector(placed, at: $0) }
                        guard points.allSatisfy(isFinite) else {
                            skipped += 1
                            continue
                        }
                        let wound = cross(points[1] - points[0], points[2] - points[0])
                        let derived = length_squared(wound) > 0 ? normalize(wound) : SIMD3(0, 0, 1)
                        for (corner, point) in zip(corners, points) {
                            positions.append(point)
                            let written = facing.map { vector($0, at: corner) }
                            if let written, isFinite(written), length_squared(written) > 0 {
                                normals.append(written)
                                hasWrittenNormals = true
                            } else {
                                normals.append(derived)
                            }
                        }
                    }
                }
            }
        }
        return Parsed(
            positions: positions, normals: normals,
            uvs: [SIMD2<Float>?](repeating: nil, count: positions.count),
            hasWrittenNormals: hasWrittenNormals, skippedLines: skipped)
    }

    /// 頂点の属性を 1 つ読む。
    private static func vector(_ data: MDLVertexAttributeData, at index: Int) -> SIMD3<Float> {
        let start = (data.dataStart + index * data.stride).assumingMemoryBound(to: Float.self)
        return SIMD3(start[0], start[1], start[2])
    }

    /// 3 つの成分がすべて有限か。
    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
