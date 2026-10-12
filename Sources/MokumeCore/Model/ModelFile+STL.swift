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
/// 読めない STL は ``ModelFailure/unreadable(path:)`` を投げ、読めるものを投げず、読めないものを
/// でたらめな形として返さない、というのが公開の説明 (``Sketch/loadModel(_:normalize:)``) の約束である。
/// Model I/O の断り方は、中身ではなく大きさと頭の判定で決まるので、そのまま従うと約束が破れる ([#2347])。
///
/// - **128 バイトに満たない STL は、中身を見ずに断る** ([#2335])。面を 1 つ持つバイナリは 134 バイト
///   なので当たらないが、字下げせずに手で書いた 1 面の文字の STL は 100 バイト前後で当たる。
///   **128〜132 バイトは別の癖を持つ** — 面を 1 つも読めない文字や、面が 1 つ分に足りないバイナリを、
///   断らずに「面の無い形」として返す (133 バイトから断る)
/// - **`solid` で始まらない中身は、文字でもバイナリとして読む** ([#2336])。80〜83 バイト目の 4 バイトを
///   面の数と見て、**238,609,294 (2^32 ÷ 18 の切り捨て。2^28 = 268,435,456 より小さい) 以下ならファイルに
///   揃っている分の面を読み、超えれば断る**。文字のファイルは 84 バイト目が面の数の最上位になり、
///   それが改行・タブ・CR (0x09・0x0A・0x0D) だと値が上限を下回って、文字がでたらめな座標 (1e34 級)
///   の面として返る。84 バイト目が空白や文字なら、面の数が上限を超えて断る
/// - **`solid` で始まる文字でも、面を 1 つも読まないまま `endsolid` まで読み切ると、同じバイナリの
///   道へ落ちる** ([#2391])。面の無い STL の 1 行目が 83 文字で 84 バイト目が改行なら、でたらめな面が
///   返る。面の途中で切れた文字は、バイナリへ落ちずに断る
/// - **読めない文字を、断らずに「面の無い形」で返す。** 改行が CR だけの STL (CRLF は読める)・改行の
///   無い STL・`endloop` と `endfacet` を同じ行に並べた STL などで、面を書いていても面が 0 の形が返る。
///   `endfacet` が行の先頭にある面しか読まない
/// - 頂点が足りない面があると、次の面の頂点を食って、三角形の数が面の数より少なく、形も壊れる
///
/// ## mokume が見分けて扱う範囲
///
/// 境目を Model I/O の判定に任せず、**渡す前に頭の 84 バイトで文字かバイナリかを自分で見分け**
/// (``stlLayout(of:)``)、**文字の STL は返った三角形を書かれた面と照らす**。バイナリは 80 バイトの
/// 見出しの後ろに面の数を 4 バイトで持ち、2^24 面 (約 1,677 万面。800 MB を超える) に満たなければ
/// 最上位のバイトは 0 である。文字には出ない値なので、頭の 84 バイトに文字でないバイト (NUL・制御文字)
/// が 1 つでもあればバイナリ、すべて文字なら文字の STL か STL でない文字と見る。
///
/// - **頭がすべて文字で、小文字の `solid` で始まらない** (大文字の `SOLID`・前に空白・STL でない
///   文字) → Model I/O へ渡さず、読めないとして返す
/// - **小文字の `solid` で始まる文字** → 書かれた面の数 F (行の先頭の `endfacet` の数・
///   ``endfacetCount(head:rest:chunk:)``) を数える
///   - F が 0 → 渡さず、面の無い STL (``isEmptySTL(_:)``) なら空、そうでなければ読めないとして返す
///   - F が 1 以上 → Model I/O に読ませ (128 バイトに満たなければ、末尾を空白で 128 バイトまで埋めた
///     一時の写しで。読み手は変えない — 自前で読むと、数でない座標が 0 になるといった読み手の癖が、
///     128 バイトの前後で変わる。写しは読み終えたら消す)、**返った三角形の数 T が F と等しいときだけ
///     採る**。0 枚 (読めない文字を面の無い形で返した)・F より多い (文字をバイナリとして読み直した)・
///     F より少ない (頂点の足りない面が次の面の頂点を食った) は、読めないとして返す
/// - **頭に文字でないバイトがある** (バイナリ。見出しが `solid` で始まってもよい) → 128 バイト以上は
///   Model I/O に読ませる。128 バイトに満たないものは、Model I/O が必ず断る (面を持てない) ので渡さず、
///   84 バイトの面の無いものだけ空、ほかは読めないとして返す
///
/// 上の境目 (128 バイト・面の数の上限・文字をバイナリとして読むこと・読めない文字を面の無い形で返す
/// こと) は読み手の挙動で、`STLModelTests` が固定している。読み手が変わったら、そこが赤くなって、この
/// 節の直し時を知らせる。
///
/// **大きさや頭のバイトで結果が決まる境目が、バイナリと小さい文字に残る。** 面の数を宣言して途中で
/// 切れたバイナリは 128 バイトで結果が変わり、128 バイトに満たない文字は頭に VT・FF・NUL・DEL があると
/// バイナリに分かれて読めない ([#2493]・[#2494])。
///
/// [#1966]: https://github.com/mokume-metal/mokume/issues/1966
/// [#2335]: https://github.com/mokume-metal/mokume/issues/2335
/// [#2336]: https://github.com/mokume-metal/mokume/issues/2336
/// [#2347]: https://github.com/mokume-metal/mokume/issues/2347
/// [#2391]: https://github.com/mokume-metal/mokume/issues/2391
/// [#2493]: https://github.com/mokume-metal/mokume/issues/2493
/// [#2494]: https://github.com/mokume-metal/mokume/issues/2494
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
    /// **面の無い STL は投げずに空を返す。** 「読めなかった」と「読めたが面が無い」は別である
    /// (``ModelFailure``)。Model I/O はこれを読めないとして断るか、バイナリとして読み直して
    /// でたらめな面を返すので、文字は書かれた面が無いと分かったとき、小さいバイナリは大きさで、
    /// Model I/O へ渡さずに決める (``isEmptySTL(_:)``)。
    ///
    /// **文字の STL は、Model I/O が返した三角形を、書かれた面の数と照らして採る。** 読めない文字
    /// を面の無い形で返されても、空とは取り違えない (読めないとして返す)。
    ///
    /// - Parameter scratch: 小さい文字の STL を埋めた写しを置く場所。呼ぶ側が差し替えるのは検査だけ。
    static func loadSTL(
        _ url: URL, path: String, scratch: URL = FileManager.default.temporaryDirectory
    ) throws(ModelFailure) -> Parsed {
        // **ファイルを丸ごとは写像しない。** 頭の 128 バイトと、文字の STL なら `endfacet` を数える
        // ための通読だけを、少しずつ読む (読んでいる間に切り詰められても、読めた分で終わる)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw .unreadable(path: path)
        }
        defer { try? handle.close() }
        let head: Data
        do {
            head = try handle.read(upToCount: smallestSTLModelIOReads) ?? Data()
        } catch {
            throw .unreadable(path: path)
        }
        // 128 バイトに満たなければ、頭がファイルの全部である
        let isSmall = head.count < smallestSTLModelIOReads

        switch stlLayout(of: head) {
        case .unrecognized:
            throw .unreadable(path: path)
        case .binary:
            // 128 バイトに満たないバイナリは、読み手が必ず断る (面を持てない) ので渡さない
            guard !isSmall else { return try emptyOrUnreadable(head, path: path) }
            guard let parsed = askModelIO(url) else { throw .unreadable(path: path) }
            return parsed
        case .text:
            guard let facets = endfacetCount(head: head, rest: isSmall ? nil : handle) else {
                throw .unreadable(path: path)
            }
            guard facets > 0 else {
                // 面の書かれていない文字は、読み手に渡さない — 面を 1 つも読まないまま `endsolid`
                // まで読み切ると、バイナリとして読み直されて、でたらめな面が返りうる
                let whole = isSmall ? head : try? Data(contentsOf: url)
                guard let whole else { throw .unreadable(path: path) }
                return try emptyOrUnreadable(whole, path: path)
            }
            let parsed = isSmall ? askModelIO(paddedCopyOf: head, in: scratch) : askModelIO(url)
            // **返ってきた三角形を、文字に書かれた面と照らす。** 読み手は、読めない文字 (CR だけの
            // 改行など) を面の無い形で返し、面を読めなかった文字をバイナリとして読み直す。
            // どちらも、書かれた面の数と合わない
            guard let parsed, agrees(parsed, facets: facets) else {
                throw .unreadable(path: path)
            }
            return parsed
        }
    }

    /// Model I/O が断らない STL の最小の大きさ (バイト)。**これに満たない STL は中身を見ずに断る。**
    static let smallestSTLModelIOReads = 128

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

    /// 文字の STL が書いている面の数 (行の先頭の `endfacet` の数)。`head` は頭で、続きは `rest` から
    /// `chunk` バイトずつ読む (`nil` なら頭がファイルの全部)。読めなければ `nil`。
    ///
    /// **行の先頭 (字下げは許す) だけを数える。** 読み手が面として読むのは、`endfacet` が行の先頭にある
    /// 面だけである (同じ行に `endloop` と並べても、面を 1 行に詰めても読めない — 測った)。名前に
    /// `endfacet` を含んでも数えず、数は「読み手が読みうる面の数」になる。区切りをまたぐ語と行頭の判定の
    /// ために、手前の末尾 ``lookBehind`` バイトを持ち越す。
    static func endfacetCount(head: Data, rest: FileHandle?, chunk: Int = 1 << 20) -> Int? {
        var count = 0
        var window = head
        var carried = 0
        while true {
            count += lineStartWords("endfacet", in: window, after: carried)
            guard let rest else { return count }
            let next: Data?
            do {
                next = try rest.read(upToCount: chunk)
            } catch {
                return nil
            }
            guard let next, !next.isEmpty else { return count }
            let carry = Data(window.suffix(lookBehind))
            window = carry + next
            carried = carry.count
        }
    }

    /// 行頭の判定で、語の手前に遡って見る長さ (バイト)。字下げがこれより長ければ、行頭と見なす。
    private static let lookBehind = 256

    /// `data` のうち、**`carried` バイトより後に終わる**行頭の `word` の数。手前の `carried` バイトは
    /// 持ち越しで、そこで終わる語は前の窓で数えている。
    private static func lineStartWords(
        _ word: String, in data: Data, after carried: Int
    ) -> Int {
        let needle = Array(word.utf8)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var count = 0
            var offset = 0
            while offset < bytes.count,
                let hit = memmem(base + offset, bytes.count - offset, needle, needle.count)
            {
                let start = base.distance(to: UnsafeRawPointer(hit))
                offset = start + needle.count
                guard offset > carried else { continue }
                // 手前の空白とタブを飛ばして、行頭 (改行の直後) か。窓の頭まで空白なら、ファイルの
                // 先頭か、字下げが ``lookBehind`` より長いかなので、行頭と見る
                var before = start - 1
                while before >= 0, bytes[before] == 0x20 || bytes[before] == 0x09 { before -= 1 }
                if before < 0 || bytes[before] == 0x0A || bytes[before] == 0x0D { count += 1 }
            }
            return count
        }
    }

    /// 読み手が文字の STL から返した三角形の数が、書かれた面の数と一致するか。
    ///
    /// **一致しなければ読めないとする。** 0 枚は「読めなかった」(CR だけの改行など)、多いのは文字を
    /// バイナリとして読み直したでたらめな面、少ないのは頂点の足りない面が次の面の頂点を食った形である。
    /// 読み手は、正しい STL では退化した面 (3 点が同じ・一直線)・数でない座標の面・複数の `solid` も
    /// 1 面ずつ返す (測った)。
    private static func agrees(_ parsed: Parsed, facets: Int) -> Bool {
        parsed.positions.count / 3 + parsed.skippedLines == facets
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

    /// 小さい文字の STL を、末尾を空白で ``smallestSTLModelIOReads`` まで埋めた写しにして、
    /// Model I/O に読ませる。
    ///
    /// 読み手はファイルの道筋からしか読めないので、一時の写しを書く。**写しは読み終えたら、読めても
    /// 断られても消す。** 写しを書けなければ (一時の置き場が書けない) 断られたのと同じに `nil` を返す。
    private static func askModelIO(paddedCopyOf data: Data, in scratch: URL) -> Parsed? {
        var padded = data
        padded.append(
            contentsOf: repeatElement(UInt8(ascii: " "), count: smallestSTLModelIOReads - data.count))
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
