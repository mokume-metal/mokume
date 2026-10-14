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
/// - **文字かバイナリか** (``stlLayout(of:size:)``): まず、**大きさが 84 + 50 × 面の数と等しければバイナリ**
///   (見出しの 80 バイトは自由で、UTF-16 の BOM に見える並びでも `solid` で始まっても、面の数が 2^24 以上の
///   800 MB 超でも変わらない)。次に、**UTF-16 の文字の STL** (BOM、または先頭 12 バイトの偶数位置が ASCII で
///   奇数位置が 0・その鏡) は、添字 83 も 0 になってバイナリと取り違えるので、先に見て読めないとして返す
///   (UTF-16 は読まない)。残りは、バイナリの見出しの後ろの面の数 (4 バイト) が 2^24 面 (約 1,677 万面・
///   800 MB を超える) に満たなければ最上位のバイト (添字 83) が 0 であることで分ける。**0 ならバイナリ**。
///   0 でなければバイナリの見出しではありえないので、小文字の `solid` で始まれば文字の STL、そうでなければ
///   (大文字の `SOLID`・前に空白・STL でない文字・空) 読めないとして返す。**添字 83 が 0 でも、`solid` で始まり
///   添字 80〜82 がすべて印字できる字 (0x20 以上) なら文字として扱う** (名前に NUL を含む文字の STL。面の数が
///   約 210 万以上の宣言は 100 MB 超で、切れたバイナリと区別できる)。**頭に制御文字 (FF・VT・DEL・ESC など) が
///   あるかは見ない** — 名前に制御文字があっても文字は文字で、バイナリに回すと読み手の判定に直に渡る。
///   面の数が 2^24 以上と宣言して大きさが合わないバイナリ (切れた大きいバイナリ) は壊れているとして読めない
/// - **文字の STL** は、行の先頭の `vertex` と `endfacet` を順に数える (``scanFacets(head:rest:chunk:)``)。
///   - 面が 0 → 渡さず、面の無い STL (``isEmptySTL(_:)``) なら空、そうでなければ読めないとして返す
///   - どの面も頂点がちょうど 3 つでない → 渡さず、読めないとして返す
///   - それ以外 → Model I/O に読ませ、**返った三角形の数が面の数と等しいときだけ採る**。0 枚・多い・少ないは
///     読めないとして返す。読ませるとき、添字 83 が制御文字なら、**1 行目 (名前の行・読まれない) に空白を足して
///     添字 83 を空白にした一時の写し**を渡す (``readerHead(of:)``)。添字 83 が 0x10 以上なら読み直しは面の数が
///     上限を超えて断られるので、**読み直されて数が偶然合う**ことが無くなる。128 バイトに満たなければ、
///     末尾を空白で 128 バイトまで埋めた写しにする。読み手は変えない — 自前で読むと、数でない座標が 0 に
///     なるといった読み手の癖が、大きさの前後で変わる。写しは読み終えたら消す。**写しは、書かれた面の数が
///     読み直しの枚数 (⌊(大きさ − 84) ÷ 50⌋ か ⌊(大きさ − 82) ÷ 50⌋。読み手は最後の 48 バイトで終わる面も 1 面と
///     数える) のどちらかと同じときと、128 バイトに満たないときだけ作る** — どちらとも違うときは元のファイル
///     を読ませ、返った枚数を面の数と照らす (ファイルの全部を書き直さずに済む)
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
/// - 面の数が 2^24 以上と宣言して、大きさが 84 + 50 × 面の数と合わないバイナリ (切れた大きいバイナリ) は、
///   読めない (これまで読み手は、揃った分を読んでいた)。大きさが合う完全な大きいバイナリは読める。
///   見出しが `solid` で始まり、面の数が約 210 万 (0x202020) 以上と宣言した切れたバイナリは、文字として扱われて
///   読めない。見出しが UTF-16 風 (先頭の 12 バイトが ASCII と 0 の交互) で、大きさが合わない切れたバイナリも読めない
/// - UTF-16 の文字の STL (BOM あり・なし) は、でたらめな形ではなく読めない
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
    /// (``Parsed/derivedNormals``)。`0 0 0` の面は巻き方から求め、OBJ で向きを求めた形と同じく
    /// 両面として扱う。**どちらにするかは面ごとに決める** — 向きを書いた面と `0 0 0` の面が
    /// 混ざったファイルでも、`0 0 0` の面だけが両面になり、書いた面は片面のまま ([#2342])。
    /// **点を共有しないので、どちらも面ごとに平らに光る** — OBJ で向きを書かない形は、点を
    /// 共有する面どうしで向きが均される。
    ///
    /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
    ///
    /// **座標が数でない面は読み飛ばし、数える** (``Parsed/skippedLines``)。残すと囲みの箱も
    /// 整え方も壊れる。Model I/O が返した形のうち**写せなかった要素**も同じに数える (位置を
    /// 持たない mesh・submesh を持たない mesh・三角形でない submesh・mesh でない物・型の
    /// 合わない submesh を 1 つずつ、3 つに満たない余りの番号を submesh ごとに 1 つ)。これは
    /// 実ファイルの STL では起きず、Model I/O が契約を破ったときの防御である ([#2566])。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
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
        let size: Int
        do {
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            head = try handle.read(upToCount: smallestSTLModelIOReads) ?? Data()
        } catch {
            throw .unreadable(path: path)
        }
        // 128 バイトに満たなければ、頭がファイルの全部である
        let isSmall = head.count < smallestSTLModelIOReads

        switch stlLayout(of: head, size: size) {
        case .unrecognized:
            // UTF-8 の BOM 付きで保存された、面の無い solid は、これまでどおり空と読む
            if head.starts(with: utf8BOM), isEmptyText(head: head, rest: isSmall ? nil : handle) {
                return empty
            }
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
                guard isEmptyText(head: head, rest: isSmall ? nil : handle) else {
                    throw .unreadable(path: path)
                }
                return empty
            }
            // 面の組み立てが崩れている (頂点が 3 つでない面がある) 文字は、読み手が後ろの面の頂点を
            // 食ってでたらめな形を返しうるので、渡さない
            guard scan.isWellFormed else { throw .unreadable(path: path) }
            let parsed = askModelIO(
                text: url, head: head, rest: isSmall ? nil : handle, scratch: scratch,
                facets: scan.facets, size: size)
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

    /// 頭 (先頭の 84 バイト以上) で、文字の STL かバイナリの STL かを見分ける。`size` はファイルの大きさ
    /// (分かるときだけ)。
    ///
    /// **まず、大きさが 84 + 50 × 面の数 (添字 80〜83) と等しければバイナリ** (欠けも余りも無い、完全な
    /// バイナリ。見出しの 80 バイトは自由なので、UTF-16 の BOM に見える並びでも、`solid` で始まっても、
    /// 面の数が 2^24 以上 (800 MB 以上) でも、バイナリである)。
    ///
    /// 次に **UTF-16 の文字の STL** (``isUTF16(_:)``) は、ASCII の字の上位バイトが 0 なので添字 83 も 0 になり、
    /// バイナリと取り違える。読み手はそれを読み直して、でたらめな三角形を返す (726 バイトの 4 面が 12 面・
    /// 座標 1e-39 級)。UTF-16 は読まない (説明にあるのは ASCII の文字の STL) ので、どちらでもないとして読めない。
    ///
    /// 残りは、**バイナリの見出しの後ろの面の数 (添字 80〜83) が 2^24 面 (約 1,677 万面・800 MB を超える)
    /// に満たなければ、最上位のバイト (添字 83) は 0** であることで分ける。0 でなければバイナリの見出しでは
    /// ありえないので、`solid` で始まるものは文字の STL、そうでなければ読めないとする。頭に制御文字 (FF・VT・
    /// DEL・ESC など) があるかどうかは見ない — 文字の STL の名前に制御文字があっても文字は文字で、バイナリに
    /// 回すと読み手の判定 (でたらめな形を返しうる) に直に渡る。
    ///
    /// **添字 83 が 0 でも、`solid` で始まり、添字 80〜82 がすべて印字できる字 (0x20 以上) なら文字として
    /// 扱う** (名前に NUL を含む文字の STL)。面の数が 0x202020 (約 210 万面) 以上と宣言して大きさが合わない
    /// バイナリは 100 MB 超の宣言で、実在の (切れた) バイナリと区別できる。通常の小さい面の数を宣言した、
    /// 見出しが `solid` の切れたバイナリは、添字 80〜82 に 0x20 未満を持つので、これまでどおりバイナリである。
    static func stlLayout(of head: Data, size: Int? = nil) -> STLLayout {
        let base = head.startIndex
        if head.count >= 84, let size {
            let faces = (0..<4).reduce(0) { $0 | Int(head[base + 80 + $1]) << (8 * $1) }
            if size == 84 + 50 * faces { return .binary }
        }
        if isUTF16(head) { return .unrecognized }
        let isSolid = head.starts(with: "solid".utf8)
        if head.count >= 84, head[base + 83] == 0 {
            let printable = (80..<83).allSatisfy { head[base + $0] >= 0x20 }
            return isSolid && printable ? .text : .binary
        }
        return isSolid ? .text : .unrecognized
    }

    /// UTF-16 (または UTF-32) の文字の STL の頭か。BOM の FF FE・FE FF で始まるか、先頭の 12 バイト (6 字) が
    /// 「偶数位置が ASCII の印字できる字か空白で奇数位置が 0 (LE)」「偶数位置が 0 で奇数位置が ASCII (BE)」の
    /// どちらかである。BOM が無くても、前に空白や改行があっても、大文字の `SOLID` でも掛かる。
    /// バイナリの見出しがたまたまそう並んでも、大きさが 84 + 50 × 面の数と合わなければ (``stlLayout(of:size:)``
    /// は先に大きさを見る) 読めない側に倒れる。
    private static func isUTF16(_ head: Data) -> Bool {
        var bytes = [UInt8](head.prefix(12))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return true }
        bytes = Array(bytes.prefix(bytes.count - bytes.count % 2))
        guard bytes.count >= 8 else { return false }
        func ascii(_ byte: UInt8) -> Bool { (0x20...0x7E).contains(byte) || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        let little = stride(from: 0, to: bytes.count, by: 2).allSatisfy { ascii(bytes[$0]) && bytes[$0 + 1] == 0 }
        let big = stride(from: 0, to: bytes.count, by: 2).allSatisfy { bytes[$0] == 0 && ascii(bytes[$0 + 1]) }
        return little || big
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
        // 窓の手前 (持ち越した部分より前) で、最後の空白でない字が改行か (ファイルの先頭も行頭)。
        // 字下げが持ち越す長さより長くても、行頭かどうかが区切りで変わらないようにする
        var lineStartBefore = true
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
                tally(
                    window, after: carried, isLast: upcoming == nil, lineStartBefore: lineStartBefore,
                    into: &scan, vertices: &vertices)
                guard let more = upcoming else { break }
                let carry = Data(window.suffix(lookBehind))
                lineStartBefore = isLineStart(
                    before: window.count - carry.count, in: window, outer: lineStartBefore)
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

    /// 区切りをまたいで持ち越す長さ (バイト)。字下げがこれより長くても、持ち越した部分の手前の答え
    /// (``isLineStart(before:in:outer:)``) を引き継ぐので、行頭の判定は区切りで変わらない。
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
    ///
    /// `lineStartBefore` は、窓の手前が行頭か (窓の頭まで空白が続くとき、その手前で決める)。
    private static func tally(
        _ window: Data, after carried: Int, isLast: Bool, lineStartBefore: Bool,
        into scan: inout FacetScan, vertices: inout Int
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
                    // 窓の頭まで空白なら、窓の手前で決める
                    if before < 0 ? lineStartBefore : (bytes[before] == 0x0A || bytes[before] == 0x0D) {
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

    /// `window` の `offset` より手前で、最後の空白でない字が改行か。`offset` までが全部空白なら、窓の手前の
    /// 答え (`outer`) を引き継ぐ。
    private static func isLineStart(before offset: Int, in window: Data, outer: Bool) -> Bool {
        window.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = offset - 1
            while index >= 0, isBlank(bytes[index]) { index -= 1 }
            return index < 0 ? outer : (bytes[index] == 0x0A || bytes[index] == 0x0D)
        }
    }

    /// 読み手が文字の STL から返した三角形の数が、書かれた面の数と一致するか。
    ///
    /// **一致しなければ読めないとする。** 0 枚は「読めなかった」(CR だけの改行など)、多いのは文字を
    /// バイナリとして読み直したでたらめな面、少ないのは頂点の足りない面が次の面の頂点を食った形である。
    /// 読み手は、正しい STL では退化した面 (3 点が同じ・一直線)・数でない座標の面・複数の `solid` も
    /// 1 面ずつ返す (測った)。
    ///
    /// ``Parsed/skippedLines`` は、数でない座標の面のほかに、写せなかった要素も数える ([#2566])。実ファイルの
    /// STL ではそれは起きず (Model I/O が契約を破ったときの防御)、ここで足すのは読み飛ばした面だけである。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
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
        let objects = asset.childObjects(of: MDLMesh.self)
        guard error == nil, objects.contains(where: { $0 is MDLMesh }) else { return nil }
        return triangles(of: objects)
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
        text url: URL, head: Data, rest: FileHandle?, scratch: URL, facets: Int, size: Int
    ) -> Parsed? {
        let prepared = readerHead(of: head)
        guard rest == nil || prepared != head else { return askModelIO(url) }
        // **書かれた面の数が、読み直しの枚数 ⌊(大きさ − 84) ÷ 50⌋ とも ⌊(大きさ − 82) ÷ 50⌋ とも違えば、写しを
        // 作らず、元のファイルを読ませる** (写しは、ファイルの全部を書き直す — ディスクも二重に要る)。
        // 読み手が文字を読み直すと、**揃った面 (50 バイト) の数を返し、最後の 48 バイトで終わる面も 1 面と
        // 数える**ので、枚数は必ずそのどちらかになる (測った。面の数が 2^24 以上と宣言された形は、大きさが
        // 838,860,884 バイトに満たなければ、ある分だけを返す)。だから、書かれた面の数と違う数が返れば
        // 読み直し (または読めなかった) で、合う数が返れば文字として読めた証になる。照合は呼ぶ側が行う。
        // 数が同じなら読み直しと見分けられないので、写しで読む
        if rest != nil, size < 84 + 50 * (1 << 24), facets != (size - 84) / 50, facets != (size - 82) / 50 {
            return askModelIO(url)
        }
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

    /// 読み手に渡す頭。添字 83 が制御文字 (NUL を含む 0…0x0F) なら、1 行目の終わりに空白を足して、添字 83 を空白に
    /// する (1 行目が 84 バイトより長いときは、その位置の字を空白に替える)。
    static func readerHead(of head: Data) -> Data {
        var bytes = [UInt8](head)
        guard bytes.count > 83, (0...0x0F).contains(bytes[83]) else { return head }
        if let end = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }), end <= 83 {
            bytes.insert(contentsOf: repeatElement(0x20, count: 84 - end), at: end)
        } else {
            bytes[83] = 0x20
        }
        return Data(bytes)
    }

    /// 面を 1 つも持たない、形の整った STL か。
    ///
    /// バイナリは 80 バイトの見出しと面の数 (0) だけの 84 バイト。文字は ``isEmptyText(head:rest:)``。
    /// **0 バイトは含めない** — どちらの形にもなっておらず、書き出しに失敗したファイルであることが多い。
    static func isEmptySTL(_ data: Data) -> Bool {
        if data.count == 84, data[data.startIndex + 80..<data.endIndex].allSatisfy({ $0 == 0 }) {
            return true
        }
        return isEmptyText(head: data, rest: nil)
    }

    /// 面を 1 つも持たない、形の整った文字の STL か。`head` は頭で、続きは `rest` から 1 MiB ずつ読む
    /// (`nil` なら頭がファイルの全部)。
    ///
    /// 小文字の `solid` で始まる 1 行目 (名前は何でもよい) の後ろに、空でない行が `endsolid` で始まる
    /// 1 行だけある。**行は LF・CR で割り**、VT・FF は名前の中の字として扱う (読み手がそう読む)。
    /// **ファイルは全体を載せず、断片ごとに見る** (74 MB の 1 行の STL でも、常駐は断片 1 つ分)。
    ///
    /// **UTF-8 の BOM は飛ばす** (BOM 付きで保存された、面の無い solid も空と読む)。行の頭と後ろの空白は、
    /// ASCII の空白・タブに加えて、UTF-8 の空白 (NBSP・U+1680・U+2000〜200B・U+202F・U+205F・U+3000) も落とす。
    static func isEmptyText(head: Data, rest: FileHandle?) -> Bool {
        let body = head.starts(with: utf8BOM) ? head.dropFirst(utf8BOM.count) : head[...]
        guard body.starts(with: "solid".utf8) else { return false }
        var scan = EmptySolidScan()
        func feed(_ data: Data.SubSequence) -> Bool {
            data.withUnsafeBytes { bytes in
                var index = 0
                while index < bytes.count {
                    // 次の改行まで何も決まらない間 (1 行目・開きの 8 バイトを過ぎた行の続き) は、まとめて飛ばす
                    if scan.skipsToNewline {
                        while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                        if index == bytes.count { break }
                    }
                    if !scan.accept(bytes[index]) { return false }
                    index += 1
                }
                return true
            }
        }
        guard feed(body) else { return false }
        if let rest {
            do {
                try rest.seek(toOffset: UInt64(head.count))
                while true {
                    guard let data = try autoreleasepool(invoking: { try rest.read(upToCount: 1 << 20) }),
                        !data.isEmpty
                    else { break }
                    guard feed(data[...]) else { return false }
                }
            } catch {
                return false
            }
        }
        return scan.finish()
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 1 行目の後ろを 1 バイトずつ見て、空でない行が `endsolid` で始まる 1 行だけかを決める。
    private struct EmptySolidScan {
        private var firstLineEnded = false
        private var lineHasContent = false
        private var lines = 0
        /// 最初の空でない行の、字下げの後ろの 8 バイト
        private var opening: [UInt8] = []
        /// 行頭の、UTF-8 の空白かどうかがまだ決まらない先頭のバイト
        private var pending: [UInt8] = []

        /// UTF-8 で書いた、ASCII の外の空白 (`Foundation` の `.whitespaces` のうち ASCII でないもの)
        private static let wideBlanks: [[UInt8]] =
            [[0xC2, 0xA0], [0xE1, 0x9A, 0x80], [0xE3, 0x80, 0x80], [0xE2, 0x81, 0x9F], [0xE2, 0x80, 0xAF]]
            + (0x80...0x8B).map { [0xE2, 0x80, UInt8($0)] }

        /// 1 バイト見る。もう空でないと決まれば `false`。
        mutating func accept(_ byte: UInt8) -> Bool {
            let isNewline = byte == 0x0A || byte == 0x0D
            guard firstLineEnded else {
                firstLineEnded = isNewline
                return true
            }
            if isNewline {
                guard commitPending() else { return false }
                lineHasContent = false
                return true
            }
            if !lineHasContent {
                if pending.isEmpty, ModelFile.isBlank(byte) { return true }
                pending.append(byte)
                if Self.wideBlanks.contains(pending) {
                    pending = []
                    return true
                }
                if Self.wideBlanks.contains(where: { $0.count > pending.count && $0.starts(with: pending) }) {
                    return true
                }
                return commitPending()
            }
            if lines == 1, opening.count < 8 { opening.append(byte) }
            return true
        }

        /// 空白と決まらなかった行頭のバイトを、行の中身として数える。
        private mutating func commitPending() -> Bool {
            guard !pending.isEmpty else { return true }
            lineHasContent = true
            lines += 1
            guard lines == 1 else { return false }
            for byte in pending where opening.count < 8 { opening.append(byte) }
            pending = []
            return true
        }

        /// 次の改行まで、何を読んでも結果が変わらないか。
        var skipsToNewline: Bool { !firstLineEnded || (lineHasContent && opening.count == 8) }

        /// 終わりまで見て、空でない行が `endsolid` で始まる 1 行だけか。
        mutating func finish() -> Bool {
            guard commitPending() else { return false }
            return lines == 1 && opening == Array("endsolid".utf8)
        }
    }

    /// Model I/O の形から、三角形の並びを写す。
    ///
    /// **写せなかった要素は、黙って捨てず `skipped` に数える** ([#2566]): mesh でない物・位置を
    /// 持たない mesh・submesh を持たない mesh・型の合わない submesh・三角形でない submesh を
    /// 1 つずつ、3 つに満たない余りの番号を submesh ごとに 1 つ。数える単位は面ではなく、
    /// 写せなかった要素である。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
    static func triangles(of objects: [MDLObject]) -> Parsed {
        let meshes = objects.compactMap { $0 as? MDLMesh }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var derivedNormals: [Bool] = []
        var skipped = objects.count - meshes.count

        for mesh in meshes {
            guard
                let placed = mesh.vertexAttributeData(
                    forAttributeNamed: MDLVertexAttributePosition, as: .float3)
            else {
                skipped += 1
                continue
            }
            let facing = mesh.vertexAttributeData(
                forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let written = mesh.submeshes ?? []
            let submeshes = written.compactMap { $0 as? MDLSubmesh }
            skipped += written.count - submeshes.count
            // 位置はあっても submesh が 1 つも無ければ、写すものが無い
            if written.count == 0 { skipped += 1 }
            for submesh in submeshes {
                guard submesh.geometryType == .triangles else {
                    skipped += 1
                    continue
                }
                // **番号の置き場も、その写しも、読み終わるまで手放さない。** 型を変えた番号の
                // 置き場は新しく作られ、写し (`map`) はそれを持ち続けない — 一時の値のまま
                // 写すと、指した先がすぐに消えて番号がでたらめになる
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                withExtendedLifetime((placed, facing, buffer, map)) {
                    let indices = UnsafeBufferPointer(
                        start: map.bytes.assumingMemoryBound(to: UInt32.self),
                        count: submesh.indexCount)
                    // 3 つに満たない余りは面にならない。捨てるが、数える
                    if indices.count % 3 != 0 { skipped += 1 }
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
                                derivedNormals.append(false)
                            } else {
                                normals.append(derived)
                                derivedNormals.append(true)
                            }
                        }
                    }
                }
            }
        }
        return Parsed(
            positions: positions, normals: normals,
            uvs: [SIMD2<Float>?](repeating: nil, count: positions.count),
            derivedNormals: derivedNormals, skippedLines: skipped)
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
