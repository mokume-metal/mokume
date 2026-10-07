// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// モデルのファイルを、置ける形へ落とす。
///
/// 読むのは **OBJ と STL** (``Format``)。拡張子で読み手を選ぶ — OBJ は自前の読み手
/// (``parse(_:)``)、STL は Model I/O (``loadSTL(_:path:)``)。どちらも形 (三角形と面の
/// 向き) と展開だけを ``Parsed`` へ落とし、その先の整え方 (``Model/make(name:parsed:fitting:)``)
/// は同じものを通る。材質・テクスチャ・複数の物体は読まない — 読み込んだ色と `fill()` の
/// どちらが勝つかという規則が要るので、まず「読んで置ける」を通す ([ADR-0008])。
///
/// **OBJ を Model I/O へ回さない。** Model I/O も OBJ を読めるが、読み飛ばした行の数・
/// `vt` の縦の向き・負の番号の扱いといった、自前の読み手が約束してきた結果が動く
/// ([#1966](https://github.com/mokume-metal/mokume/issues/1966))。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが解釈を別の仕事として
/// 回すため ([ADR-0010])。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum ModelFile {
    /// 読める形式。**読み手の選び方と、断るときの説明 (``ModelFailure``) はこの一覧から作る**
    /// — 足せば両方が揃い、別々に書いた一覧がずれることが無い。
    enum Format: String, CaseIterable, Sendable {
        case obj
        case stl

        /// 拡張子から引く。**大文字小文字は問わない** (`.STL` で書き出す道具がある)。
        init?(extensionName: String) {
            self.init(rawValue: extensionName.lowercased())
        }

        /// 名前から引く。拡張子が無いか、読めない形式なら `nil`。
        init?(path: String) {
            self.init(extensionName: (path as NSString).pathExtension)
        }

        /// 人に見せる名前 (`OBJ (.obj)`)。
        var displayName: String { "\(rawValue.uppercased()) (.\(rawValue))" }
    }

    /// 面を 1 つも持たない読み取り結果。
    static let empty = Parsed(
        positions: [], normals: [], uvs: [], hasWrittenNormals: false, skippedLines: 0)

    /// 読み取った中身。正規化する前の形。
    struct Parsed: Sendable, Equatable {
        /// 三角形の頂点の位置 (ファイルの座標のまま・3 つで 1 枚)。
        var positions: [SIMD3<Float>]
        /// 頂点ごとの面の向き。``positions`` と同じ数だけ並ぶ。
        var normals: [SIMD3<Float>]
        /// 頂点ごとの読み取り位置。``positions`` と同じ数だけ並ぶ。
        ///
        /// **`nil` は「この角に `vt` が無い」**を表す。書いてある角と無い角が混ざった
        /// モデルがあるので、モデル単位ではなく角ごとに持つ — 書かれた展開は活かし、
        /// 欠けた角だけが囲みの箱へ倒れる (倒し方は ``Model/make(name:parsed:fitting:)``)。
        ///
        /// **縦はこの面の約束 (下向き) へ直してある。** OBJ の `vt` は下から上へ数えるので
        /// 読んだ時点で `1 - v` にしている。位置の縦軸を裏返すのは整える側の仕事
        /// (``Model``) だが、こちらは**整えの対象ではない** — 読み取り位置は形の座標では
        /// なく絵を読む位置なので、`normalize` の有無で値が変わってはならない。
        var uvs: [SIMD2<Float>?]
        /// 面の向きが**ファイルに書かれていた**か。
        ///
        /// 書かれていなければ形から求める。求めた向きは**両面**として扱う —
        /// 巻き方が逆なモデルが真っ黒になるのを避けるためで、その場で並べた頂点と
        /// 同じ規則である (#290)。
        var hasWrittenNormals: Bool
        /// 読み飛ばしたものの数。**読み飛ばしたことが分かる手段**として持つ。
        ///
        /// OBJ では読み飛ばした行、STL では読み飛ばした面 (座標が数でない面) を数える。
        var skippedLines: Int
    }

    /// 名前から探して読む。**拡張子で読み手を選ぶ** (``Format``)。
    static func load(_ path: String) throws(ModelFailure) -> Parsed {
        let searched = ImageFile.candidates(for: path)
        guard let url = searched.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw .notFound(path: path, searched: searched.map(\.path))
        }
        guard let format = Format(extensionName: url.pathExtension) else {
            throw .unsupported(path: path, extensionName: url.pathExtension.lowercased())
        }
        switch format {
        case .obj:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw .unreadable(path: path)
            }
            return parse(text)
        case .stl:
            return try loadSTL(url, path: path)
        }
    }

    /// OBJ の文字列を三角形の並びへ落とす。
    ///
    /// **読めない行で止まらない。** 途中に知らない行があっても、そこまでの形は
    /// 使えるほうが役に立つ (数えて知らせる)。
    static func parse(_ text: String) -> Parsed {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var textures: [SIMD2<Float>] = []
        /// 面の頂点 (位置の番号・読み取り位置の番号・向きの番号)。
        var faces: [[(position: Int, texture: Int?, normal: Int?)]] = []
        var skipped = 0

        for line in text.lines {
            let fields = line.split(whereSeparator: \.isWhitespaceQuickly)
            guard let keyword = fields.first else { continue }
            let values = fields.dropFirst()
            switch keyword {
            case "v":
                guard let point = vector(values) else { skipped += 1; continue }
                positions.append(point)
            case "vn":
                guard let point = vector(values) else { skipped += 1; continue }
                normals.append(point)
            case "vt":
                guard let point = texture(values) else { skipped += 1; continue }
                textures.append(point)
            case "f":
                let corners = values.compactMap {
                    corner(
                        $0, positions: positions.count, textures: textures.count,
                        normals: normals.count)
                }
                guard corners.count >= 3 else { skipped += 1; continue }
                faces.append(corners)
            case "#", "":
                continue
            default:
                // 材質・物体の区切り・なめらかさの指定などは読まない
                skipped += 1
            }
        }

        return assemble(
            positions: positions, normals: normals, textures: textures, faces: faces,
            skipped: skipped)
    }

    /// 読み取った並びを三角形へ畳む。
    private static func assemble(
        positions: [SIMD3<Float>], normals: [SIMD3<Float>], textures: [SIMD2<Float>],
        faces: [[(position: Int, texture: Int?, normal: Int?)]], skipped: Int
    ) -> Parsed {
        let hasWrittenNormals = !normals.isEmpty && faces.contains { $0.contains { $0.normal != nil } }

        // 向きが書かれていなければ、**面の向きを頂点ごとに足し込んでから正規化する**。
        // 3 つずつ独立に処理すると、帯状・扇状に並べた形の後ろの頂点が既定値のまま残る
        var derived = [SIMD3<Float>](repeating: .zero, count: positions.count)
        if !hasWrittenNormals {
            for face in faces {
                let corners = face.map { positions[$0.position] }
                let facing = newell(corners)
                for corner in face { derived[corner.position] += facing }
            }
        }

        var placedPositions: [SIMD3<Float>] = []
        var placedNormals: [SIMD3<Float>] = []
        var placedUVs: [SIMD2<Float>?] = []
        for face in faces {
            // 多角形は扇状に割る。凹んだ面は正しく割れないが、OBJ の面はふつう凸である
            for index in 1..<(face.count - 1) {
                for corner in [face[0], face[index], face[index + 1]] {
                    placedPositions.append(positions[corner.position])
                    placedUVs.append(corner.texture.map { textures[$0] })
                    if let written = corner.normal, written < normals.count {
                        placedNormals.append(normals[written])
                    } else {
                        let sum = derived[corner.position]
                        placedNormals.append(
                            length_squared(sum) > 0 ? normalize(sum) : SIMD3(0, 0, 1))
                    }
                }
            }
        }
        return Parsed(
            positions: placedPositions, normals: placedNormals, uvs: placedUVs,
            hasWrittenNormals: hasWrittenNormals, skippedLines: skipped)
    }

    /// 面の向きを、周の形から求める (Newell の方法)。
    private static func newell(_ corners: [SIMD3<Float>]) -> SIMD3<Float> {
        var facing = SIMD3<Float>.zero
        for index in corners.indices {
            let current = corners[index]
            let next = corners[(index + 1) % corners.count]
            facing.x += (current.y - next.y) * (current.z + next.z)
            facing.y += (current.z - next.z) * (current.x + next.x)
            facing.z += (current.x - next.x) * (current.y + next.y)
        }
        return facing
    }

    /// 3 つの数を読む。
    private static func vector(_ fields: ArraySlice<Substring>) -> SIMD3<Float>? {
        let numbers = fields.prefix(3).compactMap { Float($0) }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    /// 読み取り位置を読む (`u v [w]`)。
    ///
    /// **3 つ目 (w) は読み飛ばさず無視する。** 立体的な読み取りを書いたモデルでも、
    /// 手前の 2 つは正しい展開なので使える。`v` が無い行は 0 として読む。
    ///
    /// **縦はここで裏返す。** OBJ の `v` は絵の下から上へ数え、この面の読み取り位置は
    /// 上から下へ数える (``SolidMesh/Point/uv``)。裏返さないと、貼った絵が上下逆に乗る。
    private static func texture(_ fields: ArraySlice<Substring>) -> SIMD2<Float>? {
        let numbers = fields.prefix(2).compactMap { Float($0) }
        guard let u = numbers.first, u.isFinite else { return nil }
        let v = numbers.count >= 2 ? numbers[1] : 0
        guard v.isFinite else { return nil }
        return SIMD2(u, 1 - v)
    }

    /// 面の 1 つの角 (`位置/読み取り位置/向き`) を読む。
    ///
    /// 番号は 1 から数える。**負の番号は末尾からの数え方**なので、そのまま足す。
    private static func corner(
        _ field: Substring, positions: Int, textures: Int, normals: Int
    ) -> (position: Int, texture: Int?, normal: Int?)? {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, let raw = Int(first) else { return nil }
        guard let position = resolve(raw, count: positions) else { return nil }
        // **`a//c` は真ん中が空**という書き方 (読み取り位置を持たない角)
        var texture: Int?
        if parts.count >= 2, let rawTexture = Int(parts[1]) {
            texture = resolve(rawTexture, count: textures)
        }
        var normal: Int?
        if parts.count >= 3, let rawNormal = Int(parts[2]) {
            normal = resolve(rawNormal, count: normals)
        }
        return (position, texture, normal)
    }

    /// 1 から数える番号 (負なら末尾から) を、0 から数える番号へ直す。
    private static func resolve(_ raw: Int, count: Int) -> Int? {
        let index = raw > 0 ? raw - 1 : count + raw
        return (0..<count).contains(index) ? index : nil
    }
}
