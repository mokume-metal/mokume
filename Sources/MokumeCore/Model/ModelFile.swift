// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// モデルのファイルを、置ける形へ落とす。
///
/// 読むのは **OBJ と STL** (``Format``)。拡張子で読み手を選ぶ — OBJ は自前の読み手
/// (``parse(_:)``)、STL は Model I/O (``loadSTL(_:path:scratch:)``)。どちらも形 (三角形と面の
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
        positions: [], normals: [], uvs: [], derivedNormals: [], skippedLines: 0)

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
        /// 頂点ごとに、面の向きを**形から求めた**か (ファイルに書かれていなかったか)。
        /// ``positions`` と同じ数だけ並ぶ。
        ///
        /// 書かれていなければ形から求める。求めた向きは**両面**として扱う —
        /// 巻き方が逆なモデルが真っ黒になるのを避けるためで、その場で並べた頂点と
        /// 同じ規則である (#290)。
        ///
        /// **モデル単位ではなく角ごとに持つ** ([#2342])。向きを書いた面と書かない面が
        /// 混ざったファイル (OBJ の `vn` のある面と無い面・STL の `facet normal 0 0 0` の面と
        /// 書いた面) があり、1 つの印に畳むと、書かない面の向きを求めない (OBJ) か、求めた
        /// 面が両面にならない (STL)。OBJ の 1 つの面の中で `vn` のある角と無い角が混ざって
        /// いても、角ごとに決める (その場で並べた頂点と同じ)。**長さ 0 の向き** (OBJ の
        /// `vn 0 0 0`・STL の `facet normal 0 0 0`) は書いていないものとして扱う。
        ///
        /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
        var derivedNormals: [Bool]
        /// 読み飛ばしたものの数。**読み飛ばしたことが分かる手段**として持つ。
        ///
        /// OBJ では読み飛ばした行、STL では読み飛ばした面 (座標が数でない面) と、Model I/O が
        /// 返した形のうち写せなかった要素 (位置を持たない mesh・三角形でない submesh・3 つに
        /// 満たない余りの番号など) を数える。数える単位は形式と要素で違い、面の数ではない。
        /// **OBJ は行を丸ごと読み飛ばす** — 面の行に位置の番号が読めない角 (範囲の外・0・
        /// 数でない) が 1 つでもあれば、残りの角で面を作らず、その行を数える。行末のコメント
        /// (`#` から後) と継ぎ文字 (`\`) は角でない字で、読めない角に数えない。
        ///
        /// **読めない `v`・`vt`・`vn` の行は番号の枠を 1 つ使い (#2564)、詰めない。** 数えるのは
        /// 読めない行 1 つ分で、その行を位置として指す面は行ごと読み飛ばして面の行ごとに 1 つ
        /// 足す (読めない `v` 1 行を 2 つの面の行が指せば 3)。`vt`・`vn` を指す角は書いて
        /// いない角と同じに読み、足さない。
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
        // **読めない行も番号の枠を 1 つ使う** (#2564)。OBJ の番号は行の通し番号なので、読めない
        // 行を詰めると後ろの番号が 1 つずつずれ、面が別の頂点を指して形が黙って変わる。枠は
        // 0 で埋めて置き、読めなかった行の番号だけを別の集合に持つ (`Optional` の配列にすると
        // 大きな OBJ で要素が倍の幅になり、最後に外す写しも要る)。数える読み飛ばしは、読めない
        // 行 1 つ分のままである
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var textures: [SIMD2<Float>] = []
        var unreadablePositions: Set<Int> = []
        var unreadableNormals: Set<Int> = []
        var unreadableTextures: Set<Int> = []
        /// 面の頂点 (位置の番号・読み取り位置の番号・向きの番号)。
        var faces: [[(position: Int, texture: Int?, normal: Int?)]] = []
        var skipped = 0

        for line in text.lines {
            let fields = line.split(whereSeparator: \.isWhitespaceQuickly)
            guard let keyword = fields.first else { continue }
            // **向きは 3 つの数まで** (`vn i j k`)。4 つ目以降があれば欄を空にして、読めない行として
            // 数える (#2566)。行末のコメント (`# …`) は欄に数えない。`v` の 4 つ目 (w・色) と
            // `vt` の 3 つ目 (w) は仕様にある欄なので、それは読み捨てる
            let values =
                keyword == "vn" && fields.dropFirst().prefix(while: { !$0.hasPrefix("#") }).count > 3
                ? ArraySlice<Substring>() : fields.dropFirst()
            switch keyword {
            case "v":
                let point = vector(values)
                if point == nil {
                    skipped += 1
                    unreadablePositions.insert(positions.count)
                }
                positions.append(point ?? .zero)
            case "vn":
                let point = vector(values)
                if point == nil {
                    skipped += 1
                    unreadableNormals.insert(normals.count)
                }
                normals.append(point ?? .zero)
            case "vt":
                let point = texture(values)
                if point == nil {
                    skipped += 1
                    unreadableTextures.insert(textures.count)
                }
                textures.append(point ?? .zero)
            case "f":
                // **位置の番号が読めない角が 1 つでもあれば、行ごと読み飛ばす** (#2339)。読める
                // 角だけで面を作ると、5 角形が四角形になったことが数えられずに消える。読み
                // 飛ばす単位は、1 つでも数が読めない `v` の行と同じく行である
                //
                // **角でない字は角として読まない。** 行末のコメント (`#` から後) と継ぎ文字 (`\`) は
                // 読めない角ではなく、並べただけの字である。読めない角と同じに数えると、
                // `f 1 2 3 4 # quad` が丸ごと消える (`v` の行は 3 つ目までしか読まないので残る)
                let written = Self.cornerFields(values)
                var corners: [(position: Int, texture: Int?, normal: Int?)] = []
                for value in written {
                    guard
                        var read = corner(
                            value, positions: positions.count, textures: textures.count,
                            normals: normals.count),
                        unreadablePositions.isEmpty || !unreadablePositions.contains(read.position)
                    else { break }
                    // 読めない `vt`・`vn` の行を指す角は、その番号を書いていない角と同じに読む
                    // (番号が読めない・範囲の外と同じ。#2349・#2564)
                    if let index = read.texture, unreadableTextures.contains(index) {
                        read.texture = nil
                    }
                    if let index = read.normal, unreadableNormals.contains(index) {
                        read.normal = nil
                    }
                    corners.append(read)
                }
                guard corners.count == written.count, corners.count >= 3 else {
                    skipped += 1
                    continue
                }
                faces.append(corners)
            case "#", "":
                continue
            default:
                // 材質・物体の区切り・なめらかさの指定などは読まない
                skipped += 1
            }
        }

        // 面が指すのは読めた行だけ (上で確かめてある)。枠だけの 0 は指されない
        return assemble(
            positions: positions, normals: normals, textures: textures, faces: faces,
            skipped: skipped)
    }

    /// 読み取った並びを三角形へ畳む。
    private static func assemble(
        positions: [SIMD3<Float>], normals: [SIMD3<Float>], textures: [SIMD2<Float>],
        faces: [[(position: Int, texture: Int?, normal: Int?)]], skipped: Int
    ) -> Parsed {
        // 向きが書かれていない角があれば、**面の向きを頂点ごとに足し込んでから正規化する**。
        // 3 つずつ独立に処理すると、帯状・扇状に並べた形の後ろの頂点が既定値のまま残る
        //
        // **書かれていない角が 1 つでもあれば求める** (#2342)。ファイルに 1 つでも `vn` が
        // あると求めなかった頃は、`vn` の無い面が既定の (0, 0, 1) へ倒れていた。足し込むのは
        // すべての面で、向きを書いた面も形としては点の周りの面である。どの面も書いていない
        // ファイルは、いままでと 1 ビットも違わない
        //
        // **長さ 0 の `vn` は書いていないのと同じ** (#2342 の反証)。書いたと読むと、形から求めず
        // 両面にもならず、向き 0 の頂点として光を受けない。STL の `facet normal 0 0 0` と
        // `normal(0, 0, 0)` も同じく書いていない側へ倒している (非有限の `vn` は行ごと読み
        // 飛ばすので、ここには届かない)
        func written(_ corner: (position: Int, texture: Int?, normal: Int?)) -> Int? {
            guard let index = corner.normal, length_squared(normals[index]) > 0 else { return nil }
            return index
        }
        var derived = [SIMD3<Float>](repeating: .zero, count: positions.count)
        if faces.contains(where: { $0.contains { written($0) == nil } }) {
            for face in faces {
                let corners = face.map { positions[$0.position] }
                let facing = newell(corners)
                for corner in face { derived[corner.position] += facing }
            }
        }

        var placedPositions: [SIMD3<Float>] = []
        var placedNormals: [SIMD3<Float>] = []
        var placedUVs: [SIMD2<Float>?] = []
        var placedDerived: [Bool] = []
        for face in faces {
            // 多角形は扇状に割る。凹んだ面は正しく割れないが、OBJ の面はふつう凸である
            for index in 1..<(face.count - 1) {
                for corner in [face[0], face[index], face[index + 1]] {
                    placedPositions.append(positions[corner.position])
                    placedUVs.append(corner.texture.map { textures[$0] })
                    // 番号は ``corner(_:positions:textures:normals:)`` が範囲を確かめてある。
                    // 範囲の外の番号は「書いていない」として届く
                    if let written = written(corner) {
                        placedNormals.append(normals[written])
                        placedDerived.append(false)
                    } else {
                        let sum = derived[corner.position]
                        placedNormals.append(
                            length_squared(sum) > 0 ? normalize(sum) : SIMD3(0, 0, 1))
                        placedDerived.append(true)
                    }
                }
            }
        }
        return Parsed(
            positions: placedPositions, normals: placedNormals, uvs: placedUVs,
            derivedNormals: placedDerived, skippedLines: skipped)
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
        let numbers = fields.prefix(3).compactMap(number)
        guard numbers.count == 3 else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    /// 読み取り位置を読む (`u v [w]`)。
    ///
    /// **3 つ目 (w) は読み飛ばさず無視する。** 立体的な読み取りを書いたモデルでも、
    /// 手前の 2 つは正しい展開なので使える。`v` が無い行は 0 として読む — **書いてあって
    /// 読めない `v` は無いのではない**ので、行ごと読み飛ばす ([#2514])。
    ///
    /// **縦はここで裏返す。** OBJ の `v` は絵の下から上へ数え、この面の読み取り位置は
    /// 上から下へ数える (``SolidMesh/Point/uv``)。裏返さないと、貼った絵が上下逆に乗る。
    ///
    /// [#2514]: https://github.com/mokume-metal/mokume/issues/2514
    private static func texture(_ fields: ArraySlice<Substring>) -> SIMD2<Float>? {
        let written = fields.prefix(2)
        let numbers = written.compactMap(number)
        guard let u = numbers.first, numbers.count == written.count else { return nil }
        let v = numbers.count >= 2 ? numbers[1] : 0
        return SIMD2(u, 1 - v)
    }

    /// 頂点の 1 つの数を読む。**10 進の綴りで、有限の数だけ** — 読めなければ `nil`。
    ///
    /// 綴りの判定は値を取り出す口と共有する (``DecimalText``)。Swift の `Float(String)` に
    /// 任せると、OBJ の文法に無い 16 進 (`0x10`) が数として置かれ、読めない行が数えられない
    /// ([#2514])。10 進でも `Float` に収まらない数 (`1e39`) は無限なので、ここで断る。
    ///
    /// [#2514]: https://github.com/mokume-metal/mokume/issues/2514
    private static func number(_ field: Substring) -> Float? {
        guard let value = DecimalText.float(String(field)), value.isFinite else { return nil }
        return value
    }

    /// 面の 1 つの角 (`位置/読み取り位置/向き`) を読む。
    ///
    /// 番号は 1 から数える。**負の番号は末尾からの数え方**なので、そのまま足す。
    private static func corner(
        _ field: Substring, positions: Int, textures: Int, normals: Int
    ) -> (position: Int, texture: Int?, normal: Int?)? {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        // **欄は最大 3 つ** (`位置/読み取り位置/向き`)。4 つ目以降があれば読めない角で、黙って
        // 捨てて三角形にはしない — 面の行ごと読み飛ばして数える (#2566・#2339)
        guard parts.count <= 3, let first = parts.first, let raw = Int(first) else { return nil }
        guard let position = resolve(raw, count: positions) else { return nil }
        // **`a//c` は真ん中が空**という書き方 (読み取り位置を持たない角)。
        // 番号が数として読めない (`a/x/c`)・範囲の外 (`a/99/c`) も、書いていない角と同じに
        // 読む — 面は残し、読み飛ばした行には数えない ([#2349])。`vn` も同じ
        //
        // [#2349]: https://github.com/mokume-metal/mokume/issues/2349
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

    /// 面の行のうち、角として読む欄。**行末のコメントと継ぎ文字を除く** (#2339)。
    ///
    /// `#` を含む欄はその手前までを残して打ち切る (`4#quad` は `4`)。最後の欄が継ぎ文字 `\`
    /// だけなら落とす — 次の行へ続ける書き方だが、続きを繋いでは読まない (直す前と同じく、
    /// この行の角だけで面を作る)。
    private static func cornerFields(_ values: ArraySlice<Substring>) -> [Substring] {
        var fields: [Substring] = []
        for value in values {
            if let mark = value.firstIndex(of: "#") {
                if mark > value.startIndex { fields.append(value[..<mark]) }
                break
            }
            fields.append(value)
        }
        if fields.last == "\\" { fields.removeLast() }
        return fields
    }
}
