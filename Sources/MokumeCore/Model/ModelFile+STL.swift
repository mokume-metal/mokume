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
/// - 改行が CRLF でも読む。途中で切れたバイナリは、揃っている面だけを読む
/// - **数として読めない座標は、文字の STL では黙って 0 になる** (`nan`・`a` など)。バイナリの
///   NaN・無限はそのまま返る
/// - 0 バイト・84 バイトに満たないファイル・**面が 1 つも無い STL**・`solid` で始まらない文字の
///   STL (大文字の `SOLID`・前に空白)・途中で切れた文字の STL は、読めないとして返す
///
/// [#1966]: https://github.com/mokume-metal/mokume/issues/1966
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
    /// **面の無い STL は投げずに空を返す。** Model I/O はこれも読めないとして返すが、「読めな
    /// かった」と「読めたが面が無い」は別である (``ModelFailure``)。見分けるのは Model I/O が
    /// 断ったときだけ (``isEmptySTL(_:)``)。
    static func loadSTL(_ url: URL, path: String) throws(ModelFailure) -> Parsed {
        var error: NSError?
        let asset = MDLAsset(
            url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false,
            error: &error)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard error == nil, !meshes.isEmpty else {
            if let data = try? Data(contentsOf: url), isEmptySTL(data) { return empty }
            throw .unreadable(path: path)
        }
        return triangles(of: meshes)
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
