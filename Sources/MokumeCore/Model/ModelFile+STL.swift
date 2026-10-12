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
///   揃っている分の面を読み、超えれば断る**。文字のファイルは 84 バイト目 (添字 83) が面の数の最上位に
///   なり、それが改行・タブ・CR など 0x10 未満の制御文字だと値が上限を下回って、文字がでたらめな座標
///   (1e34 級) の面として返る。84 バイト目が空白や文字なら、面の数が上限を超えて断る
/// - **`solid` で始まる文字でも、面を 1 つも読めないまま読み切ると、同じバイナリの道へ落ちる**
///   ([#2391])。面の無い STL の 1 行目が 83 文字で 84 バイト目が改行なら、でたらめな面が返る。`facet` の
///   行に `normal` が無い・大文字の `FACET NORMAL`・`facet` の行が無い文字も、面を 1 つも読めずに同じ道へ
///   落ち、**読み直した枚数 ⌊(大きさ − 84) ÷ 50⌋ が書かれた面の数と一致すれば、数では見分けられない**。
///   面の途中で切れた文字は、バイナリへ落ちずに断る
/// - **読めない文字を、断らずに「面の無い形」で返す。** 改行が CR だけの STL (CRLF は読める)・改行の
///   無い STL・`endloop` と `endfacet` を同じ行に並べた STL などで、面を書いていても面が 0 の形が返る。
///   `endfacet` が行の先頭にある面しか読まない。字下げは空白・タブ・VT・FF を読み飛ばす
/// - 頂点が足りない面や多い面があると、隣の面の頂点を食って、形が壊れる。足りない数と多い数が打ち消し
///   合う並びでも、面の数は合う
///
/// ## mokume が見分けて扱う範囲
///
/// 境目を Model I/O の判定に任せず、**頭で文字かバイナリかを見分け** (``stlLayout(of:)``)、**文字の STL は
/// 面の組み立てを自分で確かめてから渡し、読み手が読み直す余地を残さず、返った三角形を書かれた面と照らす**。
///
/// - **文字かバイナリか**: バイナリの見出しの後ろの面の数 (4 バイト) は、2^24 面 (約 1,677 万面・800 MB
///   を超える) に満たなければ最上位のバイト (添字 83) が 0 である。**0 ならバイナリ**。0 でなければ
///   バイナリの見出しではありえないので、小文字の `solid` で始まれば文字の STL、そうでなければ (大文字の
///   `SOLID`・前に空白・STL でない文字・空) 読めないとして返す。**頭に制御文字 (FF・VT・DEL・ESC など) が
///   あるかは見ない** — 名前に制御文字があっても文字は文字で、バイナリに回すと読み手の判定に直に渡る。
///   面の数が 2^24 以上のバイナリは壊れているとして読めない
/// - **文字の STL** は、行の先頭の `vertex` と `endfacet` を順に数える (``scanFacets(head:rest:chunk:)``)。
///   - 面が 0 → 渡さず、面の無い STL (``isEmptySTL(_:)``) なら空、そうでなければ読めないとして返す
///   - どの面も頂点がちょうど 3 つでない → 渡さず、読めないとして返す
///   - それ以外 → Model I/O に読ませ、**返った三角形の数が面の数と等しいときだけ採る**。0 枚・多い・少ないは
///     読めないとして返す。読ませるとき、添字 83 が制御文字なら、**1 行目 (名前の行・読まれない) に空白を足して
///     添字 83 を空白にした一時の写し**を渡す (``readerHead(of:)``)。添字 83 が 0x10 以上なら読み直しは面の数が
///     上限を超えて断られるので、**読み直されて数が偶然合う**ことが無くなる。128 バイトに満たなければ、
///     末尾を空白で 128 バイトまで埋めた写しにする。読み手は変えない — 自前で読むと、数でない座標が 0 に
///     なるといった読み手の癖が、大きさの前後で変わる。写しは読み終えたら消す
/// - **バイナリ**は 128 バイト以上を Model I/O に読ませる。128 バイトに満たないものは、Model I/O が必ず
///   断る (面を持てない) ので渡さず、84 バイトの面の無いものだけ空、ほかは読めないとして返す
///
/// 上の境目 (128 バイトと 128〜132 バイトの癖・面の数の上限・文字をバイナリとして読むこと・読み直しの
/// 形・読めない文字を面の無い形で返すこと・VT と FF を空白として読むこと) は読み手の挙動で、
/// `STLModelTests` が固定している。読み手が変わったら、そこが赤くなって、この節の直し時を知らせる。
///
/// **残る境目**: 面の数を宣言して途中で切れたバイナリは、128 バイトで結果が変わる ([#2493])。文字の STL
/// では、座標が足りない `vertex` の行や数でない座標を、読み手が 0 として読む (上の読み手の癖)。頂点の数
/// と面の数の確かめでは見えない。
///
/// ## 挙動が変わるもの (これまで読めた・空になったものが、読めないとして返る)
///
/// すべて、公開の説明の約束 (小文字の `solid` で始まらない・壊れている・読めない文字は投げる) に合う側へ
/// 揃えた。
///
/// - 前に空白やタブのある、面の無い solid (`  solid t` + `endsolid t`) は、空ではなく読めない
/// - 頂点の無い面だけの STL は、空ではなく読めない。頂点の無い面と正しい面が混ざったものは、正しい 1 面を
///   返さずに読めない
/// - 改行が CR だけの STL・改行の無い STL は、128 バイト以上でも空ではなく読めない
/// - 頂点が 3 つでない面を含む文字の STL は、壊れた形ではなく読めない
/// - 面の数が 2^24 以上のバイナリは、読めない
/// - 逆に、読めるようになったもの: 128 バイトに満たない文字の STL (#2335)・名前に FF・VT・NUL・DEL・ESC を
///   含む文字の STL (#2494)・名前に UTF-8 でない字を含む面の無い solid (空になる)
///
/// [#1966]: https://github.com/mokume-metal/mokume/issues/1966
/// [#2335]: https://github.com/mokume-metal/mokume/issues/2335
/// [#2336]: https://github.com/mokume-metal/mokume/issues/2336
/// [#2347]: https://github.com/mokume-metal/mokume/issues/2347
/// [#2391]: https://github.com/mokume-metal/mokume/issues/2391
/// [#2493]: https://github.com/mokume-metal/mokume/issues/2493
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
    /// - Parameter scratch: Model I/O に読ませる写しを置く場所。呼ぶ側が差し替えるのは検査だけ。
    static func loadSTL(
        _ url: URL, path: String, scratch: URL = FileManager.default.temporaryDirectory
    ) throws(ModelFailure) -> Parsed {
        // **ファイルを丸ごとは写像しない。** 頭の 128 バイトと、文字の STL なら面を数えるための
        // 通読だけを、少しずつ読む (読んでいる間に切り詰められても、読めた分で終わる)
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
            guard let scan = scanFacets(head: head, rest: isSmall ? nil : handle) else {
                throw .unreadable(path: path)
            }
            guard scan.facets > 0 else {
                // 面の書かれていない文字は、読み手に渡さない — 面を 1 つも読まないまま `endsolid`
                // まで読み切ると、バイナリとして読み直されて、でたらめな面が返りうる
                let whole = isSmall ? head : try? Data(contentsOf: url)
                guard let whole else { throw .unreadable(path: path) }
                return try emptyOrUnreadable(whole, path: path)
            }
            // 面の組み立てが崩れている (頂点が 3 つでない面がある) 文字は、読み手が後ろの面の頂点を
            // 食ってでたらめな形を返しうるので、渡さない
            guard scan.isWellFormed else { throw .unreadable(path: path) }
            let parsed = askModelIO(
                text: url, head: head, rest: isSmall ? nil : handle, scratch: scratch)
            // **返ってきた三角形を、文字に書かれた面の数と照らす。** 読み手は、読めない文字 (CR だけの
            // 改行など) を面の無い形で返す。数が合わなければ読めなかったのと同じである
            guard let parsed, agrees(parsed, facets: scan.facets) else {
                throw .unreadable(path: path)
            }
            return parsed
        }
    }

    /// Model I/O が断らない STL の最小の大きさ (バイト)。**これに満たない STL は中身を見ずに断る。**
    static let smallestSTLModelIOReads = 128

    /// 頭から見分けた、STL の形。
    enum STLLayout: Sendable, Equatable {
        /// 文字の STL (小文字の `solid` で始まり、バイナリの見出しではありえない)。
        case text
        /// バイナリの STL (84 バイトの見出しと面の数を持ち、面の数の最上位のバイトが 0)。
        case binary
        /// どちらでもない (空・前に空白のある文字・大文字の `SOLID`・STL でない文字)。
        case unrecognized
    }

    /// 頭 (先頭の 84 バイト以上) で、文字の STL かバイナリの STL かを見分ける。
    ///
    /// **バイナリの見出しの後ろの面の数 (4 バイト・添字 80〜83) は、2^24 面 (約 1,677 万面・800 MB を
    /// 超える) に満たなければ最上位のバイト (添字 83) が 0 である。** そこが 0 でなければバイナリの
    /// 見出しではありえないので、`solid` で始まるものは文字の STL、そうでなければ読めないとする。
    /// 頭に制御文字 (FF・VT・DEL・ESC など) があるかどうかは見ない — 文字の STL の名前に制御文字が
    /// あっても文字は文字で、バイナリに回すと読み手の判定 (でたらめな形を返しうる) に直に渡る。
    /// 面の数が 2^24 以上のバイナリは、壊れているとして読めないものに入る。
    static func stlLayout(of head: Data) -> STLLayout {
        if head.count >= 84, head[head.startIndex + 83] == 0 { return .binary }
        return head.starts(with: "solid".utf8) ? .text : .unrecognized
    }

    /// 読み手が面として読む語を数えた結果。
    struct FacetScan: Equatable {
        /// 面の数 (行の先頭の `endfacet` の数)。
        var facets = 0
        /// どの面も、行の先頭の `vertex` をちょうど 3 つ持ち、最後の `endfacet` の後ろに余りが無い。
        var isWellFormed = true
    }

    /// 文字の STL の面を数える。`head` は頭で、続きは `rest` から `chunk` バイトずつ読む (`nil`
    /// なら頭がファイルの全部)。読めなければ `nil`。
    ///
    /// **行の先頭 (字下げは空白・タブ・VT・FF) の `vertex` と `endfacet` だけを数え、後ろが空白・改行・
    /// 終端の語に限る。** 読み手が面として読むのは、そう書かれた面だけである (`endloop` と並べても、
    /// 面を 1 行に詰めても、CR だけの改行でも読めない — 測った)。名前の中の語や `endfacets` は数えず、
    /// 数は「読み手が読みうる面の数」になる。区切りをまたぐ語と行頭の判定のために、手前の末尾
    /// ``lookBehind`` バイトを持ち越し、語の後ろの 1 バイトが次の区切りにあるものは次の窓で数える。
    static func scanFacets(head: Data, rest: FileHandle?, chunk: Int = 1 << 20) -> FacetScan? {
        var scan = FacetScan()
        var vertices = 0
        var window = head
        var carried = 0
        func nextChunk() throws -> Data? {
            guard let rest else { return nil }
            // **読むたびに自動解放の置き場を空ける。** 空けないと、読んだ断片が外側の置き場が空くまで
            // 消えず、ファイル全体が常駐する (74 MB の STL で 86 MB・測った)
            let data = try autoreleasepool { try rest.read(upToCount: chunk) }
            return (data?.isEmpty ?? true) ? nil : data
        }
        do {
            var upcoming = try nextChunk()
            while true {
                tally(window, after: carried, isLast: upcoming == nil, into: &scan, vertices: &vertices)
                guard let more = upcoming else { break }
                let carry = Data(window.suffix(lookBehind))
                window = carry + more
                carried = carry.count
                upcoming = try nextChunk()
            }
        } catch {
            return nil
        }
        // 最後の `endfacet` の後ろに頂点が余っている面は、書き終えていない
        if vertices != 0 { scan.isWellFormed = false }
        return scan
    }

    /// 行頭の判定で、語の手前に遡って見る長さ (バイト)。字下げがこれより長ければ、行頭と見なす。
    private static let lookBehind = 256

    private static let vertexWord = Array("vertex".utf8)
    private static let endfacetWord = Array("endfacet".utf8)

    /// 字下げに使う空白 (空白・タブ・VT・FF)。読み手は VT・FF も空白として読む。
    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    /// `window` に現れる行頭の `vertex` と `endfacet` を、現れる順に `scan` へ数える。**語の後ろの
    /// 1 バイトを見て決める**ので、`carried` バイトより手前で決まった語 (前の窓で数えた) は飛ばし、後ろの
    /// 1 バイトがまだ読めていない語 (窓の終わりで終わる語。`isLast` でなければ) は次の窓へ回す。
    private static func tally(
        _ window: Data, after carried: Int, isLast: Bool, into scan: inout FacetScan,
        vertices: inout Int
    ) {
        var events: [(at: Int, isEnd: Bool)] = []
        window.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            for (word, isEnd) in [(vertexWord, false), (endfacetWord, true)] {
                var offset = 0
                while offset < bytes.count,
                    let hit = memmem(base + offset, bytes.count - offset, word, word.count)
                {
                    let start = base.distance(to: UnsafeRawPointer(hit))
                    offset = start + word.count
                    guard offset >= carried else { continue }
                    if offset == bytes.count {
                        if !isLast { continue }
                    } else {
                        let after = bytes[offset]
                        guard isBlank(after) || after == 0x0A || after == 0x0D else { continue }
                    }
                    var before = start - 1
                    while before >= 0, isBlank(bytes[before]) { before -= 1 }
                    // 窓の頭まで空白なら、ファイルの先頭か、字下げが ``lookBehind`` より長いかなので、
                    // 行頭と見る
                    if before < 0 || bytes[before] == 0x0A || bytes[before] == 0x0D {
                        events.append((start, isEnd))
                    }
                }
            }
        }
        events.sort { $0.at < $1.at }
        for event in events {
            if event.isEnd {
                if vertices != 3 { scan.isWellFormed = false }
                scan.facets += 1
                vertices = 0
            } else {
                vertices += 1
            }
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

    /// 文字の STL を Model I/O に読ませる。**読み手が、面を読めなかった文字をバイナリとして読み直す余地
    /// を残さない。**
    ///
    /// 読み直しは、添字 80〜83 を面の数と見て、238,609,294 以下のときだけ起こる。添字 83 が 0x10 以上
    /// なら面の数が上限を超えて、読み直しは断られる。そこで添字 83 が制御文字 (タブ・改行・CR など)
    /// なら、**1 行目 (`solid` の行。名前は読まれない) に空白を足して**添字 83 を空白にした写しを読ませる。
    /// 頂点にも面にも触れない。128 バイトに満たなければ、末尾を空白で 128 バイトまで埋める。
    /// 写しが要らなければ (添字 83 が文字で、128 バイト以上) 元のファイルを読ませる。
    ///
    /// 写しは一時の置き場に書き、**読み終えたら、読めても断られても消す。** 写しを書けなければ、128 バイト
    /// に満たないものは断られたのと同じに `nil` を、それ以上のものは元のファイルを読ませる。
    private static func askModelIO(
        text url: URL, head: Data, rest: FileHandle?, scratch: URL
    ) -> Parsed? {
        let prepared = readerHead(of: head)
        guard rest == nil || prepared != head else { return askModelIO(url) }
        let directory = scratch.appendingPathComponent(
            "mokume-stl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("model.stl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: copy.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: copy)
            defer { try? output.close() }
            var written = prepared.count
            try output.write(contentsOf: prepared)
            if let rest {
                try rest.seek(toOffset: UInt64(head.count))
                while true {
                    let data = try autoreleasepool { try rest.read(upToCount: 1 << 20) }
                    guard let data, !data.isEmpty else { break }
                    try autoreleasepool { try output.write(contentsOf: data) }
                    written += data.count
                }
            }
            if written < smallestSTLModelIOReads {
                let padding = Data(repeating: 0x20, count: smallestSTLModelIOReads - written)
                try output.write(contentsOf: padding)
            }
        } catch {
            return rest == nil ? nil : askModelIO(url)
        }
        return askModelIO(copy)
    }

    /// 読み手に渡す頭。添字 83 が制御文字 (1…0x0F) なら、1 行目の終わりに空白を足して、添字 83 を空白に
    /// する (1 行目が 84 バイトより長いときは、その位置の字を空白に替える)。
    static func readerHead(of head: Data) -> Data {
        var bytes = [UInt8](head)
        guard bytes.count > 83, (1...0x0F).contains(bytes[83]) else { return head }
        if let end = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }), end <= 83 {
            bytes.insert(contentsOf: repeatElement(0x20, count: 84 - end), at: end)
        } else {
            bytes[83] = 0x20
        }
        return Data(bytes)
    }

    /// 面を 1 つも持たない、形の整った STL か。
    ///
    /// バイナリは 80 バイトの見出しと面の数 (0) だけの 84 バイト。文字は小文字の `solid` で始まる 1 行目
    /// (名前は何でもよい) の後ろに、空でない行が `endsolid` で始まる 1 行だけある。**行は LF・CR で
    /// 割り**、VT・FF は名前の中の字として扱う (読み手がそう読む)。**0 バイトは含めない** — どちらの形にも
    /// なっておらず、書き出しに失敗したファイルであることが多い。
    static func isEmptySTL(_ data: Data) -> Bool {
        if data.count == 84, data[data.startIndex + 80..<data.endIndex].allSatisfy({ $0 == 0 }) {
            return true
        }
        guard data.starts(with: "solid".utf8) else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            func isNewline(_ index: Int) -> Bool { bytes[index] == 0x0A || bytes[index] == 0x0D }
            var index = 0
            while index < bytes.count, !isNewline(index) { index += 1 }
            var lines = 0
            var endsolid = false
            while index < bytes.count {
                while index < bytes.count, isNewline(index) { index += 1 }
                var low = index
                while index < bytes.count, !isNewline(index) { index += 1 }
                var high = index
                while low < high, isBlank(bytes[low]) { low += 1 }
                while high > low, isBlank(bytes[high - 1]) { high -= 1 }
                guard low < high else { continue }
                lines += 1
                if lines > 1 { return false }
                endsolid = UnsafeRawBufferPointer(rebasing: bytes[low..<high])
                    .starts(with: "endsolid".utf8)
            }
            return lines == 1 && endsolid
        }
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
