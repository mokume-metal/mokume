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
/// - 改行が CRLF でも読む。途中で切れたバイナリは、揃っている面だけを、宣言した面の数まで読む
///   (向きと 3 点の 48 バイトがあれば 1 面と数え、後ろの属性の 2 バイトは問わない。最初の面だけは、下の
///   128〜132 バイトの癖で 49 バイトから)。文字の STL は、面の途中で切れていれば断り、面の境 (`endfacet` の後) で
///   切れていれば `endsolid` が無くても揃った面を読む
/// - **数として読めない座標は、文字の STL では黙って 0 になる** (`nan`・`a` など)。バイナリの
///   NaN・無限はそのまま返る
/// - **文字の STL は、`facet normal` (間の空白 1 つ) の綴りが添字 127 までに始まらないと、面を 1 つも読めない**
///   ([#2645])。綴りの位置だけを見て、名前の中の綴りでもよい。名前が 121 文字以上 (字下げ 2 の `facet normal` が
///   添字 130)・最初の面の字下げが長い・前に空白の行や空行を挟んだ・面の行の区切りがタブや空白 2 つ、のどれでも
///   下の「バイナリの道」へ落ちる。探しに行けた後は、区切りがタブや空白 2 つの面の行も読む。境目は行の長さでは
///   ない — 2 つ目の `solid` の名前・`vertex` の行の字下げや行末の空白が長くても読み、座標は 40 桁でも 1200 桁でも
///   切らずに読む
/// - **行は LF だけで割り、`outer` の行から `endloop` の行までの空でない行を、語によらず頂点として読む** ([#2645])。
///   `vertex` で始まらない行 (`foo`・`# comment`・大文字の `VERTEX`・NUL や NBSP だけの行・空白・タブ・VT・FF・CR
///   だけの行) は頂点 (0, 0, 0) になる。CRLF の空行は CR だけの行なので当たる。2 つの `vertex` の行を CR 1 つで繋ぐと
///   1 つの頂点になる。頂点を 3 つずつ区切り直した枚数と、余りの番号を返す。`facet normal` と `outer` の間・`endloop`
///   と `endfacet` の間の、空白だけの行も含む空でない行では断り、`outer` の無い面も断る。`endloop` の無い面は
///   `endfacet` を頂点として読む。本当に空の行 (LF だけ) と、面と面の間・`endsolid` の前後の行は読み飛ばす
///
/// ## Model I/O の境目は、公開の説明と食い違う
///
/// 読めない STL は ``ModelFailure/unreadable(path:)`` を投げ、読めるものを投げず、読めないものを
/// でたらめな形として返さない、というのが公開の説明 (``SketchPart/loadModel(_:normalize:)``) の約束である。
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
/// - **バイナリでも、見出しが `solid` で始まり `facet normal` の綴り (上の添字 127 まで) を含むと、文字として読み、
///   面の無い形を返す** ([#2746])。大きさが 84 + 50 × 面の数と合う完全なバイナリでも、途中で切れたものでも同じ。
///   `solid` だけ・`facet normal` だけの見出しなら、バイナリとして読む
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
/// - **文字の STL** は、行を LF だけで割り (読み手と同じ)、行の先頭の `vertex` と `endfacet` を順に数える
///   (``scanFacets(head:rest:chunk:)``)。
///   - 面が 0 → 渡さず、面の無い STL (``isEmptyText(head:rest:)``) なら空、そうでなければ読めないとして返す
///   - どの面も頂点がちょうど 3 つでない・面の中に読み手が頂点と読む行や断る行がある (`vertex` でない行・
///     `outer loop` や `endloop` の無い面。空白だけの行は除く) → 渡さず、読めないとして返す ([#2645])
///   - それ以外 → Model I/O に読ませ、**返った三角形の数が面の数と等しく、写せなかった要素 (3 つに満たない余りの
///     番号など) が無いときだけ採る**。0 枚・多い・少ない・余りは読めないとして返す。読ませるとき、添字 83 が制御文字なら、**1 行目 (名前の行・読まれない) に空白を足して
///     添字 83 を空白にした一時の写し**を渡す (``readerHead(of:)``)。添字 83 が 0x10 以上なら読み直しは面の数が
///     上限を超えて断られるので、**読み直されて数が偶然合う**ことが無くなる。128 バイトに満たなければ、
///     末尾を空白で 128 バイトまで埋めた写しにする。読み手は変えない — 自前で読むと、数でない座標が 0 に
///     なるといった読み手の癖が、大きさの前後で変わる。写しは読み終えたら消す。**写しは、書かれた面の数が
///     読み直しの枚数 (⌊(大きさ − 84) ÷ 50⌋ か ⌊(大きさ − 82) ÷ 50⌋。読み手は最後の 48 バイトで終わる面も 1 面と
///     数える) のどちらかと同じときと、128 バイトに満たないときだけ作る** — どちらとも違うときは元のファイル
///     を読ませ、返った枚数を面の数と照らす (ファイルの全部を書き直さずに済む)
///   - **`facet normal` の綴りが添字 128 から先にしか無いか、面の中に空白・CR だけの行がある**なら
///     (``TextScan/needsRewrite``)、上の写しに替えて、**1 行目を `solid` と空白 (添字 83 が空白) にし、最初の面の
///     行の `normal` までを `facet normal` に替え (それより前を落とし)、空白・CR だけの行を落とした写し**を渡す
///     ([#2645])。頂点の行と 2 つ目より後ろの面の行には触れない。最初の面の行に `normal` が無い文字は、書き直さない。
///     どちらにも当たらない文字 (面と面の間・`endsolid` の前後にだけ空白の行がある文字も) は、これまでどおりの経路で
///     写しを作らない。この写しを書けなければ、上と同じに元のファイルを読ませて照らす
///   - 上の写し (添字 83・128 バイト未満) を作るときも、最初の面の行に `normal` があれば、同じ書き直しにする — 1 行目に
///     空白を足すだけでは、`facet normal` の綴りが添字 128 から先へずれうる ([#2645])
/// - **バイナリ**は、**途中で切れていても大きさによらず、揃った面だけを読む** ([#2493])。大きさから揃ったと
///   読める面の数 (``completeBinaryFaces(head:size:)``。宣言した面の数と、頭の後ろに揃った面の数の小さいほう) が
///   0 なら、Model I/O に渡さず空にする — 面の数が 0 で後ろに余りがあるものも、最初の面の途中で切れたものも、
///   84 バイトから同じに空になる。128 バイトに満たないもの (Model I/O が必ず断る) と、128〜132 バイト (Model I/O が
///   面の無い形を返す) もここに入る。1 以上なら Model I/O に読ませ、**返った三角形の数 (数でない座標で読み飛ばした
///   面も含む) が、揃ったと読める面の数と等しいときだけ採る** ([#2746])。合わず、見出しが `solid` で始まるときだけ、
///   **見出しの 80 バイトを 0 にした写し**を読ませて照らし直す (``writeBlankHeader(head:rest:to:)``。面の数と面には
///   触れない)。それでも合わない・写しを書けなければ、読めないとして返す — 面の無い形を空としては採らない。
///   普通のバイナリ (見出しが `solid` で始まらない・`facet normal` を含まない) は 1 回目で合うので、写しを作らない
///
/// 上の境目 (128 バイトと 128〜132 バイトの癖・面の数の上限・途中で切れたバイナリの揃った面の数え方・文字を
/// バイナリとして読むこと・読み直しの形・読めない文字を面の無い形で返すこと・VT と FF を空白として読むこと・
/// `facet normal` の綴りの位置の上限・面の中の空でない行を頂点として読むこと・行を LF だけで割ること・`solid` …
/// `facet normal` の見出しのバイナリを文字として読むこと) は読み手の挙動で、`STLModelTests` が固定している。読み手が
/// 変わったら、そこが赤くなって、この節の直し時を知らせる。
///
/// **残る境目**: 文字の STL では、座標が足りない `vertex` の行や数でない座標を、読み手が 0 として読む (上の
/// 読み手の癖)。頂点の数と面の数の確かめでは見えない。
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
/// - 頂点が 3 つでない面を含む文字の STL は、壊れた形ではなく読めない。2 つの `vertex` の行を CR 1 つで繋いだ
///   文字の STL は、1 面欠けた形ではなく読めない (#2645)
/// - 面の数が 2^24 以上と宣言して、大きさが 84 + 50 × 面の数と合わないバイナリ (切れた大きいバイナリ) は、
///   読めない (これまで読み手は、揃った分を読んでいた)。大きさが合う完全な大きいバイナリは読める。
///   見出しが `solid` で始まり、面の数が約 210 万 (0x202020) 以上と宣言した切れたバイナリは、文字として扱われて
///   読めない。見出しが UTF-16 風 (先頭の 12 バイトが ASCII と 0 の交互) で、大きさが合わない切れたバイナリも読めない
/// - UTF-16 の文字の STL (BOM あり・なし) は、でたらめな形ではなく読めない
/// - 逆に、読めるようになったもの: 128 バイトに満たない文字の STL (#2335)・名前に FF・VT・NUL・DEL・ESC を
///   含む文字の STL (#2494)・名前に UTF-8 でない字を含む面の無い solid (空になる)・`facet normal` の綴りが添字 128
///   から先にしか無い文字の STL (名前が 121 文字以上・最初の面の字下げが長い・面の行の区切りがタブや空白 2 つなど)・
///   面の中に空白・CR だけの行 (CRLF の空行など) がある文字の STL (#2645)。揃った面の無い 84〜127 バイトのバイナリ
///   (最初の面の途中で切れたもの・面の数が 0 で後ろに余りのあるもの) は、読めないではなく空になる (#2493)。
///   見出しが `solid` で始まり `facet normal` を含むバイナリは、面の無い形ではなく書かれた面を読む (#2746)
///
/// [#1966]: https://github.com/mokume-metal/mokume/issues/1966
/// [#2335]: https://github.com/mokume-metal/mokume/issues/2335
/// [#2336]: https://github.com/mokume-metal/mokume/issues/2336
/// [#2347]: https://github.com/mokume-metal/mokume/issues/2347
/// [#2391]: https://github.com/mokume-metal/mokume/issues/2391
/// [#2493]: https://github.com/mokume-metal/mokume/issues/2493
/// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
/// [#2746]: https://github.com/mokume-metal/mokume/issues/2746
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
    /// でたらめな面を返すので、文字は書かれた面が無いと分かったとき (``isEmptyText(head:rest:)``)、
    /// バイナリは大きさから揃った面が無いと分かったとき (``completeBinaryFaces(head:size:)``) に、
    /// Model I/O へ渡さずに決める。**途中で切れたバイナリは、揃った面だけを読む** — 揃った面が無ければ
    /// 投げずに空にする ([#2493])。
    ///
    /// [#2493]: https://github.com/mokume-metal/mokume/issues/2493
    ///
    /// **文字の STL は、Model I/O が返した三角形を、書かれた面の数と照らして採る。** 読めない文字
    /// を面の無い形で返されても、空とは取り違えない (読めないとして返す)。**バイナリも、大きさから揃ったと
    /// 読める面の数と照らす** — 見出しが `solid` で始まり `facet normal` を含むバイナリを、読み手は文字として読んで
    /// 面の無い形を返すので、見出しを 0 にした写しで読み直す ([#2746])。
    ///
    /// [#2746]: https://github.com/mokume-metal/mokume/issues/2746
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
            // **揃った面が無ければ、読み手に渡さず空にする** (#2493)。途中で切れていても、面の数が 0 で後ろに
            // 余りがあっても、大きさによらない。128 バイトに満たないもの (読み手が必ず断る) と、128〜132 バイト
            // (読み手が面の無い形を返す) もここに入る
            let faces = completeBinaryFaces(head: head, size: size)
            guard faces > 0 else { return empty }
            // **返った面の数を、揃ったと読める面の数と照らす** (#2746)。読み手は、`solid` で始まり `facet normal` を
            // 含む見出しのバイナリを文字として読み、面の無い形を返す。合わず、見出しが `solid` で始まるときだけ、見出しを
            // 0 にした写しで読み直す — 普通のバイナリは 1 回目で合うので、写しを作らない
            if let read = reading(url), agrees(read, facets: faces) { return read.parsed }
            guard head.starts(with: "solid".utf8),
                let read = try? readThroughCopy(
                    in: scratch, fill: { try writeBlankHeader(head: head, rest: handle, to: $0) }),
                agrees(read, facets: faces)
            else { throw .unreadable(path: path) }
            return read.parsed
        case .text:
            guard let text = scanText(head: head, rest: isSmall ? nil : handle) else {
                throw .unreadable(path: path)
            }
            let scan = text.shape
            guard scan.facets > 0 else {
                // 面の書かれていない文字は、読み手に渡さない — 面を 1 つも読まないまま `endsolid`
                // まで読み切ると、バイナリとして読み直されて、でたらめな面が返りうる
                guard isEmptyText(head: head, rest: isSmall ? nil : handle) else {
                    throw .unreadable(path: path)
                }
                return empty
            }
            // 面の組み立てが崩れている (頂点が 3 つでない面・面の中に読み手が頂点と読む行がある) 文字は、
            // 読み手が後ろの面の頂点を食ってでたらめな形を返しうるので、渡さない
            guard scan.isWellFormed else { throw .unreadable(path: path) }
            let read = askModelIO(
                text: url, head: head, rest: isSmall ? nil : handle, scratch: scratch,
                scan: text, size: size)
            // **返ってきた三角形を、文字に書かれた面の数と照らす。** 読み手は、読めない文字 (CR だけの
            // 改行など) を面の無い形で返す。数が合わなければ読めなかったのと同じである
            guard let read, agrees(read, facets: scan.facets) else {
                throw .unreadable(path: path)
            }
            return read.parsed
        }
    }

    /// Model I/O が断らない STL の最小の大きさ (バイト)。**これに満たない STL は中身を見ずに断る。**
    static let smallestSTLModelIOReads = 128

    /// 読み手がバイナリの最初の面を読む、ファイルの最小の大きさ (バイト)。84 バイトの頭と、最初の面の 49 バイト。
    /// 128〜132 バイトのバイナリを、読み手は面の無い形で返す。
    static let smallestBinaryWithAFace = 133

    /// バイナリの STL の頭 (84 バイト以上) が宣言する面の数 (添字 80〜83 の、リトルエンディアンの 4 バイト)。
    static func declaredBinaryFaces(in head: Data) -> Int {
        (0..<4).reduce(0) { $0 | Int(head[head.startIndex + 80 + $1]) << (8 * $1) }
    }

    /// バイナリの STL の、**大きさから揃ったと読める面の数** ([#2493])。宣言した面の数と、84 バイトの頭の後ろに
    /// 揃った面の数の小さいほうで、**読み手 (Model I/O) がバイナリとして読んで返す枚数と同じ**になる。`head` は
    /// 頭 (84 バイト以上)、`size` はファイルの大きさ。
    ///
    /// 揃ったと読むのは、向きと 3 点の 48 バイトがある面 (後ろの属性の 2 バイトは問わない)。ただし最初の面だけは
    /// 49 バイト (ファイルが ``smallestBinaryWithAFace`` バイト) から — 読み手は 128〜132 バイトのバイナリを面の無い
    /// 形で返し、128 バイトに満たなければ断る (macOS 27 で測った。`STLModelTests.modelIOReadsTheCompleteBinaryFaces`)。
    ///
    /// [#2493]: https://github.com/mokume-metal/mokume/issues/2493
    static func completeBinaryFaces(head: Data, size: Int) -> Int {
        guard size >= smallestBinaryWithAFace else { return 0 }
        return min(declaredBinaryFaces(in: head), (size - 84 + 2) / 50)
    }

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
        if head.count >= 84, let size, size == 84 + 50 * declaredBinaryFaces(in: head) {
            return .binary
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
        /// どの面も、行の先頭の `vertex` をちょうど 3 つ持ち、最後の `endfacet` の後ろに余りが無く、面の中に読み手が
        /// 読み違える行 (``scanText(head:rest:chunk:)``) が無い。
        var isWellFormed = true
    }

    /// 文字の STL を通読した結果。面の数え (``FacetScan``) に、読み手の行の読み方の癖に当たるかを足す ([#2645])。
    ///
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    struct TextScan: Equatable {
        /// 面の数と組み立て。
        var shape = FacetScan()
        /// 読み手が、文字の面を探しに行けるか — 先頭から ``facetNormalLimit`` バイトまでに `facet normal` (間の空白は
        /// 1 つ) の綴りが始まる。名前の中の綴りでもよい。
        var readerFindsFacets = false
        /// 最初の面の行 (`facet` の語で始まる行) が `facet` <空白> `normal` と続くとき、`normal` の 6 字の直後の位置
        /// (ファイルの先頭からのバイト数)。後ろの字は問わない (`normalx` でも、読み手は綴りで探しに行く)。最初の面の行に
        /// `normal` が無ければ `nil`。面の行は、面の外にある `facet` の語で始まる行に限る
        var firstFacetNormalEnd: Int?
        /// 面の中 (`facet` から `endfacet` まで・`outer` から `endloop` まで) に、空白・タブ・VT・FF・CR だけでできた行
        /// (1 バイト以上) がある。CRLF の空行もこれに当たる。面と面の間や `endsolid` の前後の空白の行は数えない
        /// (読み手は正しく読む)。
        var hasBlankLineInFacet = false

        /// 読み手に、書き直した写し (``ModelFile/writeRewritten(from:head:rest:to:)``) を渡すか。
        ///
        /// 読み手が面を探しに行けないか、面の中に空白だけの行があれば渡す。最初の面の行に `normal` が無い文字は渡さない
        /// — 書き直しても読み手は面を読めず、読めないとして返る。
        var needsRewrite: Bool {
            firstFacetNormalEnd != nil && (!readerFindsFacets || hasBlankLineInFacet)
        }
    }

    /// 読み手が文字の面を探しに行ける、`facet normal` の綴りの始まりの上限 (この添字から先では探しに行かない)。
    ///
    /// 綴りが添字 127 までに始まれば読み、128 から先では面を 1 つも読めずに、バイナリとして読み直して断るかでたらめな
    /// 面を返す (macOS 27 で測った)。見るのは綴りの位置だけで、行の先頭か・名前の中かは問わない。区切りがタブや 2 つの
    /// 空白の `facet normal` は数えず、最初の面の区切りがそうなら、2 つ目より後ろの面の綴りの位置で決まる。2 つ目の
    /// `solid` の行や `vertex` の行の長さには境目が無い ([#2645])。
    ///
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    static let facetNormalLimit = 128

    private static let facetNormalSpelling = Array("facet normal".utf8)

    /// 文字の STL の面を数える。`head` は頭で、続きは `rest` から `chunk` バイトずつ読む (`nil`
    /// なら頭がファイルの全部)。読めなければ `nil`。
    ///
    /// **行は LF だけで割り** (読み手と同じ。CR は行の頭や語の後ろの空白として扱う)、**行の先頭 (字下げは空白・タブ・
    /// VT・FF・CR) の `vertex` と `endfacet` だけを数え、後ろが空白・改行・終端の語に限る。** 読み手が面として読むのは、
    /// そう書かれた面だけである (`endloop` と並べても、面を 1 行に詰めても、CR だけの改行でも読めない — 測った)。
    /// 名前の中の語や `endfacets` は数えず、数は「読み手が読みうる面の数」になる。
    ///
    /// **読み手は、`outer` の行から `endloop` の行までの空でない行をすべて頂点として読む** (語が何でも、0 として)。
    /// そこで `vertex`・`endloop` 以外の空白だけでない行があれば、組み立てが崩れているとする (`endloop` の無い面も
    /// ここに入る)。`facet` の行と `outer` の行の間・`endloop` の行と `endfacet` の行の間の、`outer`・`endfacet` 以外の
    /// 空白だけでない行も、読み手が断るので同じにする ([#2645])。面として見るのは `facet` の行の後ろだけで、面の外の
    /// 行は (`outer` で始まっても) 読み手どおり読み飛ばす。
    ///
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    static func scanFacets(head: Data, rest: FileHandle?, chunk: Int = 1 << 20) -> FacetScan? {
        scanText(head: head, rest: rest, chunk: chunk)?.shape
    }

    /// ``scanFacets(head:rest:chunk:)`` と同じに通読し、読み手が面を探しに行けるか・最初の面の行の `normal` の位置・
    /// 面の中の空白だけの行も見る (``TextScan``)。どれも、読む区切りの幅によらない。
    static func scanText(head: Data, rest: FileHandle?, chunk: Int = 1 << 20) -> TextScan? {
        var reader = LineReader()
        reader.feed(head)
        do {
            while let rest {
                // **読むたびに自動解放の置き場を空ける。** 空けないと、読んだ断片が外側の置き場が空くまで
                // 消えず、ファイル全体が常駐する (74 MB の STL で 86 MB・測った)
                let data = try autoreleasepool { try rest.read(upToCount: chunk) }
                guard let data, !data.isEmpty else { break }
                reader.feed(data)
            }
        } catch {
            return nil
        }
        return reader.finish()
    }

    /// 字下げに使う空白 (空白・タブ・VT・FF)。読み手は VT・FF も空白として読む。
    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    /// 空白だけの行を作る字 (字下げの空白と CR)。読み手は行を LF で割るので、CRLF の空行は CR だけの行になる。
    private static func isBlankOrCR(_ byte: UInt8) -> Bool {
        isBlank(byte) || byte == 0x0D
    }

    /// 文字の STL を、断片ごとに LF で割った行として読む (``scanText(head:rest:chunk:)``)。
    ///
    /// 行ごとに見るのは、字下げの後ろの先頭 ``wordLength`` バイト (語と、その後ろの 1 バイト) だけで、残りは次の LF まで
    /// 読み飛ばす。最初の面の行だけは、`facet` の後ろの `normal` の語まで見る。断片の区切りは状態として持ち越すので、
    /// 結果は区切りの幅によらない。
    private struct LineReader {
        private enum Phase {
            /// 行の頭の空白を読み飛ばしている
            case indent
            /// 字下げの後ろの語を集めている
            case word
            /// 最初の面の行で、`facet` の後ろの空白を読み飛ばしている
            case gapBeforeNormal
            /// 最初の面の行で、`normal` の綴りと突き合わせている (何字目まで合ったか)
            case normal(Int)
            /// 次の LF まで読み飛ばす
            case skip
        }

        /// 語と、その後ろの 1 バイトが入る長さ (いちばん長い語は `endfacet` の 8 字)
        private static let wordLength = 9
        private static let normalWord = Array("normal".utf8)
        private static let vertexWord = Array("vertex".utf8)
        private static let endfacetWord = Array("endfacet".utf8)
        private static let endloopWord = Array("endloop".utf8)
        private static let outerWord = Array("outer".utf8)
        private static let facetWord = Array("facet".utf8)

        private var text = TextScan()
        private var vertices = 0
        private var inFacet = false
        private var inLoop = false
        private var sawFacetLine = false
        /// 読んだバイト数 (いま見ている字の位置)
        private var position = 0
        /// 先頭の、`facet normal` の綴りを探すぶん
        private var prefix: [UInt8] = []

        private var phase = Phase.indent
        private var lineHasBytes = false
        private var word: [UInt8] = []
        /// この行が最初の面の行になりうる (面の外で、まだ面の行を見ていない) とき、`normal` の直後の位置
        private var normalEnd: Int?

        mutating func feed(_ data: Data) {
            let wanted = ModelFile.facetNormalLimit - 1 + ModelFile.facetNormalSpelling.count
            if prefix.count < wanted { prefix += data.prefix(wanted - prefix.count) }
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var index = 0
                while index < bytes.count {
                    if case .skip = phase {
                        // 次の LF まで、まとめて飛ばす
                        guard let hit = memchr(base + index, 0x0A, bytes.count - index) else {
                            index = bytes.count
                            break
                        }
                        index = base.distance(to: UnsafeRawPointer(hit))
                    }
                    let byte = bytes[index]
                    let at = position + index
                    index += 1
                    if byte == 0x0A {
                        endLine(at: at)
                        continue
                    }
                    lineHasBytes = true
                    accept(byte, at: at)
                }
            }
            position += data.count
        }

        /// 行の中の、LF でない 1 バイトを見る。
        private mutating func accept(_ byte: UInt8, at: Int) {
            switch phase {
            case .indent:
                guard !ModelFile.isBlankOrCR(byte) else { return }
                phase = .word
                word.append(byte)
            case .word:
                word.append(byte)
                if word.count == 6, !inFacet, !inLoop, !sawFacetLine, word.starts(with: Self.facetWord),
                    ModelFile.isBlankOrCR(byte)
                {
                    phase = .gapBeforeNormal
                } else if word.count == Self.wordLength {
                    phase = .skip
                }
            case .gapBeforeNormal:
                guard !ModelFile.isBlankOrCR(byte) else { return }
                phase = byte == Self.normalWord[0] ? .normal(1) : .skip
            case .normal(let matched):
                // 読み手は `facet normal` の綴りだけを見るので、`normal` の後ろの字は問わない (`normalx` でもよい)
                if byte == Self.normalWord[matched], matched + 1 == Self.normalWord.count {
                    normalEnd = at + 1
                    phase = .skip
                } else {
                    phase = byte == Self.normalWord[matched] ? .normal(matched + 1) : .skip
                }
            case .skip:
                break
            }
        }

        /// 行の頭の語が `spelled` か (後ろが空白・CR か、行の終わり)。
        private func starts(with spelled: [UInt8]) -> Bool {
            guard word.starts(with: spelled) else { return false }
            return word.count == spelled.count || ModelFile.isBlankOrCR(word[spelled.count])
        }

        /// 行を 1 つ読み終えた。`end` は行の終わり (LF か、ファイルの終わり) の位置。
        private mutating func endLine(at end: Int) {
            defer {
                phase = .indent
                lineHasBytes = false
                word.removeAll(keepingCapacity: true)
                normalEnd = nil
            }
            guard lineHasBytes else { return }  // 空の行
            guard !word.isEmpty else {
                // 空白だけの行。読み手は面の中のそれを頂点として読む (`facet normal`・`endloop` の直後なら断る)
                if inFacet || inLoop { text.hasBlankLineInFacet = true }
                return
            }
            let isVertex = starts(with: Self.vertexWord)
            let isEndfacet = starts(with: Self.endfacetWord)
            // 数え方はこれまでどおり、どこにあっても数える
            if isVertex { vertices += 1 }
            if isEndfacet {
                if vertices != 3 { text.shape.isWellFormed = false }
                text.shape.facets += 1
                vertices = 0
            }
            if inLoop {
                if starts(with: Self.endloopWord) {
                    inLoop = false
                } else if !isVertex {
                    // 読み手が頂点 (0, 0, 0) として読む行。`endloop` の無い面の `endfacet` もここ
                    text.shape.isWellFormed = false
                    if isEndfacet { (inLoop, inFacet) = (false, false) }
                }
            } else if inFacet {
                if starts(with: Self.outerWord) {
                    inLoop = true
                } else if isEndfacet {
                    inFacet = false
                } else {
                    // `outer` の無い面・`endloop` と `endfacet` の間の行は、読み手が断る
                    text.shape.isWellFormed = false
                }
            } else if starts(with: Self.facetWord) {
                inFacet = true
                if !sawFacetLine {
                    sawFacetLine = true
                    text.firstFacetNormalEnd = normalEnd
                }
            }
            // 面の外の行 (`outer` で始まる行も) は、読み手どおり読み飛ばす
        }

        /// 読み終えた。最後の行が LF で終わらなければ、ここで閉じる。
        mutating func finish() -> TextScan {
            if lineHasBytes { endLine(at: position) }
            // 最後の `endfacet` の後ろに頂点が余っている面は、書き終えていない
            if vertices != 0 { text.shape.isWellFormed = false }
            text.readerFindsFacets =
                prefix.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
                    guard let base = bytes.baseAddress,
                        let hit = memmem(base, bytes.count, ModelFile.facetNormalSpelling, ModelFile.facetNormalSpelling.count)
                    else { return false }
                    return base.distance(to: UnsafeRawPointer(hit)) < ModelFile.facetNormalLimit
                }
            return text
        }
    }

    /// 読み手が返した三角形の数が、書かれた面の数と一致するか。文字の STL は書かれた面の数と、バイナリは大きさから
    /// 揃ったと読める面の数 (``completeBinaryFaces(head:size:)``) と照らす ([#2746])。
    ///
    /// **一致しなければ読めないとする。** 0 枚は「読めなかった」(CR だけの改行など。バイナリでは、`solid` で始まり
    /// `facet normal` を含む見出しを文字の頭と読んだとき)、多いのは文字をバイナリとして読み直したでたらめな面、
    /// 少ないのは頂点の足りない面が次の面の頂点を食った形である。
    /// 読み手は、正しい STL では退化した面 (3 点が同じ・一直線)・数でない座標の面・複数の `solid` も
    /// 1 面ずつ返す (測った)。
    ///
    /// ``Parsed/skippedLines`` は、数でない座標の面のほかに、写せなかった要素も数える ([#2566])。足してよいのは
    /// 読み飛ばした面 (数でない座標) だけで、**写せなかった要素 (`defects`) が 1 つでもあれば一致としない** — 読み手が
    /// 頂点を 3 つずつ区切れなかった余りの番号もここに入り、それを面と数えると、1 面欠けた形が数の上で合ってしまう
    /// ([#2645])。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    /// [#2746]: https://github.com/mokume-metal/mokume/issues/2746
    static func agrees(_ reading: Reading, facets: Int) -> Bool {
        reading.defects == 0 && reading.parsed.positions.count / 3 + reading.parsed.skippedLines == facets
    }

    /// Model I/O が読んだ形と、そのうち写せなかった要素の数 (数でない座標の面を除く。``triangles(of:)``)。
    typealias Reading = (parsed: Parsed, defects: Int)

    /// Model I/O にファイルを読ませ、写せなかった要素の数も返す。断られたら `nil`。
    private static func reading(_ url: URL) -> Reading? {
        var error: NSError?
        let asset = MDLAsset(
            url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false,
            error: &error)
        let objects = asset.childObjects(of: MDLMesh.self)
        guard error == nil, objects.contains(where: { $0 is MDLMesh }) else { return nil }
        return trianglesCounting(of: objects)
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
    ///
    /// **読み手が面を探しに行けない・面の中に空白だけの行がある文字** (``TextScan/needsRewrite``) は、上のどれでも
    /// なく、書き直した写し (``writeRewritten(from:head:rest:to:)``) を読ませる。**上の写しを作るときも、最初の面の
    /// 行に `facet normal` の綴りがあれば同じ書き直しにする** — 1 行目に空白を足すと、`facet normal` の綴りが
    /// 添字 128 から先へずれて、読み手が面を探しに行けなくなりうる ([#2645])。写しを書けなければ、上と同じに
    /// 元のファイルを読ませる (読み手が断るか、返った枚数が面の数と合わずに読めないとして返る)。
    ///
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    private static func askModelIO(
        text url: URL, head: Data, rest: FileHandle?, scratch: URL, scan: TextScan, size: Int
    ) -> Reading? {
        let facets = scan.shape.facets
        let prepared = readerHead(of: head)
        // **書かれた面の数が、読み直しの枚数 ⌊(大きさ − 84) ÷ 50⌋ とも ⌊(大きさ − 82) ÷ 50⌋ とも違えば、写しを
        // 作らず、元のファイルを読ませる** (写しは、ファイルの全部を書き直す — ディスクも二重に要る)。
        // 読み手が文字を読み直すと、**揃った面 (50 バイト) の数を返し、最後の 48 バイトで終わる面も 1 面と
        // 数える**ので、枚数は必ずそのどちらかになる (測った。面の数が 2^24 以上と宣言された形は、大きさが
        // 838,860,884 バイトに満たなければ、ある分だけを返す)。だから、書かれた面の数と違う数が返れば
        // 読み直し (または読めなかった) で、合う数が返れば文字として読めた証になる。照合は呼ぶ側が行う。
        // 数が同じなら読み直しと見分けられないので、写しで読む
        let countsTellAReadingApart =
            size < 84 + 50 * (1 << 24) && facets != (size - 84) / 50 && facets != (size - 82) / 50
        let readsTheOriginal =
            !scan.needsRewrite && rest != nil && (prepared == head || countsTellAReadingApart)
        guard !readsTheOriginal else { return reading(url) }
        do {
            return try readThroughCopy(in: scratch) { output in
                if let normalEnd = scan.firstFacetNormalEnd {
                    return try writeRewritten(from: normalEnd, head: head, rest: rest, to: output)
                }
                try output.write(contentsOf: prepared)
                guard let rest else { return prepared.count }
                return try prepared.count + copyRest(of: rest, from: head.count, to: output)
            }
        } catch {
            return rest == nil ? nil : reading(url)
        }
    }

    /// `rest` の `offset` バイト目から終わりまでを `output` へ写し、写したバイト数を返す。1 MiB ずつ読み、
    /// 読むたびに自動解放の置き場を空ける (ファイル全体を常駐させない)。
    private static func copyRest(of rest: FileHandle, from offset: Int, to output: FileHandle) throws -> Int {
        try rest.seek(toOffset: UInt64(offset))
        var written = 0
        while true {
            let data = try autoreleasepool { try rest.read(upToCount: 1 << 20) }
            guard let data, !data.isEmpty else { break }
            try autoreleasepool { try output.write(contentsOf: data) }
            written += data.count
        }
        return written
    }

    /// バイナリの STL の、見出しの 80 バイトを 0 にした写しを `output` へ書き、書いたバイト数を返す ([#2746])。
    /// 面の数と面には触れない。読み手は、`solid` で始まり `facet normal` を含む見出しを文字の頭と読んで、面の無い形を
    /// 返す (``loadSTL(_:path:scratch:)``)。見出しは読まれないので、0 にしても形は変わらない。
    ///
    /// [#2746]: https://github.com/mokume-metal/mokume/issues/2746
    private static func writeBlankHeader(head: Data, rest: FileHandle, to output: FileHandle) throws -> Int {
        let blanked = Data(count: 80) + head.dropFirst(80)
        try output.write(contentsOf: blanked)
        return try blanked.count + copyRest(of: rest, from: head.count, to: output)
    }

    /// 一時の置き場に写しを書き (`fill` が書いたバイト数を返す)、Model I/O に読ませる。128 バイトに満たなければ、
    /// 末尾を空白で 128 バイトまで埋める。**写しは、読めても断られても消す。** 写しを書けなければ投げる。
    private static func readThroughCopy(
        in scratch: URL, fill: (FileHandle) throws -> Int
    ) throws -> Reading? {
        let directory = scratch.appendingPathComponent(
            "mokume-stl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("model.stl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: copy.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: copy)
            defer { try? output.close() }
            let written = try fill(output)
            if written < smallestSTLModelIOReads {
                let padding = Data(repeating: 0x20, count: smallestSTLModelIOReads - written)
                try output.write(contentsOf: padding)
            }
        }
        return reading(copy)
    }

    /// 読み手に渡す、書き直した写しの頭。1 行目は `solid` の後ろを空白で埋めて 84 バイト目 (添字 83) を空白にする —
    /// 読み手が面を読めなくても、読み直しは面の数が上限を超えて断られる (``readerHead(of:)`` と同じ理由)。2 行目は
    /// 最初の面の行の頭で、区切りを空白 1 つにした `facet normal` が添字 85 から始まる (``facetNormalLimit``)。
    static let rewrittenHead = Data(("solid" + String(repeating: " ", count: 79) + "\nfacet normal").utf8)

    /// 文字の STL の、読み手が読めるように書き直した写しを `output` へ書き、書いたバイト数を返す ([#2645])。
    ///
    /// - 最初の面の行の `normal` の語の直後 (ファイルの先頭から `start` バイト目) より前を、``rewrittenHead``
    ///   (`solid` の行と `facet normal`) に替える。読み手は、`facet normal` の綴りが添字 128 から先にしか無いと面を
    ///   読めない (``facetNormalLimit``)。名前は読まれず、最初の面の行より前の行は面にならない。最初の面の行の
    ///   `facet` と `normal` の間の空白・タブは、空白 1 つになる
    /// - 空白・タブ・VT・FF・CR だけの行を、行ごと (LF も) 落とす (``BlankLineFilter``)。読み手は、`outer loop` と
    ///   `endloop` の間のそういう行を頂点 (0, 0, 0) として読み、`facet normal` や `endloop` の直後なら断る。
    ///   本当に空の行 (LF だけ) はどこでも読み飛ばすので残す
    ///
    /// 頂点の行と、2 つ目より後ろの面の行には触れない (読み手は、区切りがタブや 2 つの空白の面の行も読む)。
    ///
    /// [#2645]: https://github.com/mokume-metal/mokume/issues/2645
    private static func writeRewritten(
        from start: Int, head: Data, rest: FileHandle?, to output: FileHandle
    ) throws -> Int {
        var filter = BlankLineFilter()
        var written = rewrittenHead.count
        try output.write(contentsOf: rewrittenHead)
        func emit(_ data: Data) throws {
            let kept = filter.feed(data)
            try autoreleasepool { try output.write(contentsOf: kept) }
            written += kept.count
        }
        if let rest {
            try rest.seek(toOffset: UInt64(start))
            while true {
                let data = try autoreleasepool { try rest.read(upToCount: 1 << 20) }
                guard let data, !data.isEmpty else { break }
                try emit(data)
            }
        } else {
            try emit(Data(head.dropFirst(start)))
        }
        let left = filter.finish()
        try output.write(contentsOf: left)
        return written + left.count
    }

    /// 空白・タブ・VT・FF・CR だけでできた行 (1 バイト以上) を、LF ごと落とす。ほかの行 (空の行も) はそのまま通す。
    /// 断片をまたいでも、落とす行は変わらない。
    struct BlankLineFilter {
        /// 行の頭から続く空白・CR (この行がまだ空白だけのあいだ持っておく)
        private var held = Data()
        /// 行の中に、空白・CR でない字がもう出た
        private var inContent = true

        /// 断片を受け取り、通す分を返す。
        mutating func feed(_ data: Data) -> Data {
            var kept = Data()
            kept.reserveCapacity(data.count)
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                let start = base.assumingMemoryBound(to: UInt8.self)
                func keep(_ range: Range<Int>) { kept.append(start + range.lowerBound, count: range.count) }
                var index = 0
                while index < bytes.count {
                    if inContent {
                        // 次の LF まで、まとめて通す
                        if let hit = memchr(base + index, 0x0A, bytes.count - index) {
                            let end = base.distance(to: UnsafeRawPointer(hit))
                            keep(index..<end + 1)
                            index = end + 1
                            inContent = false
                        } else {
                            keep(index..<bytes.count)
                            index = bytes.count
                        }
                        continue
                    }
                    var end = index
                    while end < bytes.count, ModelFile.isBlankOrCR(bytes[end]) { end += 1 }
                    if end == bytes.count {
                        held.append(start + index, count: end - index)
                        index = end
                    } else if bytes[end] == 0x0A {
                        // 空白だけの行は LF ごと落とす。空の行は残す
                        if held.isEmpty, end == index { kept.append(0x0A) }
                        held.removeAll(keepingCapacity: true)
                        index = end + 1
                    } else {
                        kept.append(held)
                        keep(index..<end)
                        held.removeAll(keepingCapacity: true)
                        index = end
                        inContent = true
                    }
                }
            }
            return kept
        }

        /// 終わりに、LF で終わらなかった最後の行の空白を、そのまま返す。
        mutating func finish() -> Data {
            defer { held.removeAll() }
            return held
        }
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
        trianglesCounting(of: objects).parsed
    }

    /// ``triangles(of:)`` と同じに写し、写せなかった要素のうち、数でない座標の面を除いた数 (`defects`) も返す。
    static func trianglesCounting(of objects: [MDLObject]) -> Reading {
        var nonFinite = 0
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
                            nonFinite += 1
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
        let parsed = Parsed(
            positions: positions, normals: normals,
            uvs: [SIMD2<Float>?](repeating: nil, count: positions.count),
            derivedNormals: derivedNormals, skippedLines: skipped)
        return (parsed, skipped - nonFinite)
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
