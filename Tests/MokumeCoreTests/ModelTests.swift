// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 外で作ったモデルを読んで置く検査。GPU を要するものと、要らないものがある —
/// **要るほうは入れ子の ``ModelTests/OnCanvas`` にまとめてある**。
///
/// いちばん見たいのは **「読み込んで、そのまま置いた絵が画面に見える」** — 既定同士が
/// 噛み合っていないと、読み込みは成功しているのに絵が出ない。しかも失敗ではないので
/// 利用者は原因に辿り着けない。だから画素で確かめる。
@Suite("読み込んだモデル")
struct ModelTests {
    // MARK: - 読み取り (GPU を要さない)

    @Test("面の向きが無いモデルでも、形から求めた向きが付く")
    func normalsAreDerivedWhenMissing() throws {
        let parsed = try ModelFile.load(ModelFixture.pyramid)
        // 四角錐は側面 4 枚 (三角形 4) + 底 1 枚 (三角形 2) = 6 枚
        #expect(parsed.positions.count == 18)
        #expect(parsed.derivedNormals == Array(repeating: true, count: 18))
        #expect(parsed.normals.allSatisfy { length_squared($0) > 0.9 })
        // 読み飛ばした行 (mtllib / o / s / usemtl) を数えている
        #expect(parsed.skippedLines == 4)
    }

    /// **拡張子で読み手を選ぶようになっても、OBJ は自前の読み手で読む** (#1966)。Model I/O も
    /// OBJ を読めるが、読み飛ばした行の数・`vt` の縦の向き・負の番号の扱いが変わる。検体の 3 つは
    /// それぞれを含む (読み飛ばす行 / 縦を裏返す `vt` と負の番号 / 角ごとに欠けた `vt`)。
    @Test("OBJ のファイルを読んだ結果は、自前の読み手で文字列を読んだ結果そのもの")
    func objFilesGoThroughTheOwnReader() throws {
        let fixtures = [
            (ModelFixture.pyramid, ModelFixture.pyramidText),
            (ModelFixture.unwrapped, ModelFixture.unwrappedText),
            (ModelFixture.mixedUnwrap, ModelFixture.mixedUnwrapText),
        ]
        for (path, text) in fixtures {
            #expect(try ModelFile.load(path) == ModelFile.parse(text), "\(path)")
        }
    }

    @Test("面の向きが書いてあれば、それを使う")
    func writtenNormalsAreUsed() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vn 0 0 1
            f 1//1 2//1 3//1
            """)
        #expect(parsed.derivedNormals == [false, false, false])
        #expect(parsed.normals.allSatisfy { $0 == SIMD3(0, 0, 1) })
    }

    @Test("番号は 1 から数え、負の番号は末尾から数える")
    func indicesCountFromOneAndFromTheEnd() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            f -3 -2 -1
            """)
        #expect(parsed.positions.count == 3)
        #expect(parsed.positions[0] == SIMD3(0, 0, 0))
        #expect(parsed.positions[2] == SIMD3(0, 1, 0))
    }

    @Test("読めない行があっても、そこまでの形は使える")
    func brokenLinesDoNotStopTheRest() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 nan
            v 1 0 0
            v 0 1 0
            f 1 3 4
            g grouped
            """)
        // 数でない頂点は読まないが、番号の枠は使う (#2564)。面は元の番号で 3 点そろい、三角形になる
        #expect(parsed.positions.count == 3)
        #expect(parsed.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(parsed.skippedLines == 2)
    }

    /// 約束: 読めない行は読み飛ばして数える。**読み飛ばす単位は行** — `v` の行は 1 つでも数が
    /// 読めなければ行ごと数える。面の行も、位置の番号が読めない角 (範囲の外・0・数でない・空)
    /// が 1 つでもあれば行ごと読み飛ばして 1 数える。残りの角で面を作ると、5 角形が四角形に
    /// なったことに気付く手段が無い ([#2339])。角の `vt`・`vn` の番号の読めなさはこの外 (#2349)。
    ///
    /// [#2339]: https://github.com/mokume-metal/mokume/issues/2339
    @Test(
        "面の行に位置の番号が読めない角が 1 つでもあれば、行ごと読み飛ばして数える",
        arguments: [
            // (面の行, 三角形の数, 読み飛ばした行の数)
            ("f 1 2 3 4 99", 0, 1), ("f 1 2 0 3 4", 0, 1), ("f 1 2 x 3 4", 0, 1),
            ("f 1 2 -9 3 4", 0, 1), ("f /1 1 2 3", 0, 1), ("f 1 2 99", 0, 1),
            // 陰性対照: 読める角だけの面は面になり、数えない
            ("f 1 2 3 4", 2, 0), ("f -4 -3 -2 -1", 2, 0),
            // 角でない字 — 行末のコメント (`#` から後) と継ぎ文字 (`\`) — は角として読まない。
            // 読めない角ではないので、面は残り数えない (直す前と同じ結果)
            ("f 1 2 3 4 # quad", 2, 0), ("f 1 2 3 # x", 1, 0), ("f 1 2 3 4#quad", 2, 0),
            ("f 1 2 3 4 \\", 2, 0),
            // コメントの手前に読めない角があれば、やはり行ごと数える
            ("f 1 2 x 3 4 # quad", 0, 1), ("f 1 2 # 3 4", 0, 1),
        ])
    func facesWithAnUnreadableCornerAreSkippedWhole(line: String, triangles: Int, skipped: Int) {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 1 1 0
            v 0 1 0
            \(line)
            """)
        #expect(parsed.positions.count == triangles * 3, "\(line)")
        #expect(parsed.skippedLines == skipped, "\(line)")
    }

    /// 約束 ([#2566]): 面の角は `位置[/読み取り位置[/向き]]` の最大 3 つの欄で、**4 つ目以降の欄が
    /// ある角は読めない角**として、面の行ごと読み飛ばして数える ([#2339])。黙って 4 つ目以降を
    /// 捨てて三角形にすると、書き違いに気付く手段が無い。正しい書き方 4 通りは変わらない。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
    /// [#2339]: https://github.com/mokume-metal/mokume/issues/2339
    @Test(
        "面の角に 4 つ目以降の欄があれば、面の行ごと読み飛ばして数える",
        arguments: [
            // (面の行, 三角形の数, 読み飛ばした行の数)
            ("f 1/1/1/1 2 3", 0, 1), ("f 1 2/1/1/1 3", 0, 1), ("f 1 2 3/1/1/1", 0, 1),
            ("f 1/1/1/ 2 3", 0, 1), ("f 1/1/1/1/1 2 3", 0, 1), ("f 1//1/1 2 3", 0, 1),
            ("f 1///1 2 3", 0, 1),
            // 陰性対照: 正しい 4 通りの書き方は面になり、数えない
            ("f 1 2 3", 1, 0), ("f 1/1 2/2 3/3", 1, 0), ("f 1//1 2//1 3//1", 1, 0),
            ("f 1/1/1 2/2/1 3/3/1", 1, 0),
        ])
    func cornersWithMoreThanThreeFieldsAreSkippedWhole(line: String, triangles: Int, skipped: Int) {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0 0
            vt 1 0
            vt 0 1
            vn 0 0 1
            \(line)
            """)
        #expect(parsed.positions.count == triangles * 3, "\(line)")
        #expect(parsed.skippedLines == skipped, "\(line)")
    }

    /// 約束 ([#2566]): 向き (`vn`) は 3 つの数までで、**4 つ目以降があれば読めない行**として数える
    /// (置かない)。`v` の 4 つ目 (w・色) と `vt` の 3 つ目 (w) は OBJ の仕様にある欄なので、
    /// 読み捨てて数えない。
    ///
    /// [#2566]: https://github.com/mokume-metal/mokume/issues/2566
    @Test(
        "vn の 4 つ目以降の欄は読めない行として数え、v・vt の仕様にある欄は数えない",
        arguments: [
            // (追加する行, 読み飛ばした行の数)
            ("vn 0 0 1 1", 1), ("vn 0 0 1 abc", 1), ("vn 0 0 1 1 1", 1),
            // 陰性対照: 仕様にある欄・書き方は変わらず、数えない
            ("vn 0 0 1", 0), ("vn 0 0 1 # normal", 0), ("v 1 1 1 1", 0), ("v 1 1 1 0.5 0.5 0.5", 0), ("vt 0.5 0.5 0.5", 0),
        ])
    func normalLinesWithExtraFieldsAreSkipped(line: String, skipped: Int) {
        let base = """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0.25 0.75
            vn 0 0 1
            f 1/1/1 2/1/1 3/1/1
            """
        let plain = ModelFile.parse(base)
        let parsed = ModelFile.parse(base + "\n" + line)
        var expected = plain
        expected.skippedLines += skipped
        #expect(parsed == expected, "\(line)")
    }

    /// 約束 ([#2624]): **`#` から後は、欄の途中でもコメント**で、面の角 (`cornerFields`・#2339) に
    /// 限らず `v`・`vt`・`vn` の欄も、行の先頭の語も同じに読む。欄に貼り付いたコメント
    /// (`v 1 2 3#c`) が読めない行になると、有効な行を指す面が行ごと読み飛ばされ、空白で区切った
    /// コメント (`v 1 2 3 # c`) との差が利用者に見えない。右の「コメントを落とした行」と
    /// **まったく同じ結果** (頂点・向き・読み取り位置・数える読み飛ばし) になることで確かめる。
    ///
    /// [#2624]: https://github.com/mokume-metal/mokume/issues/2624
    @Test(
        "v の行の # 以降はコメントで、欄に貼り付いていても落としてから欄を読む",
        arguments: [
            // (コメントの付いた行, コメントを落とした行)
            ("v 1 0 0#c", "v 1 0 0"), ("v 1 0 0#", "v 1 0 0"), ("v 1 0 0 # c", "v 1 0 0"),
            ("v 1 0 0#c 9 9", "v 1 0 0"), ("v 1 0 0 1#c", "v 1 0 0 1"), ("v 1 0 0\t#c", "v 1 0 0"),
            // コメントの手前に欄が足りなければ、読めない行 (コメントの中の数は欄に数えない)
            ("v 1 0#c 0", "v 1 0"), ("v 1#0 0 0", "v 1"), ("v 1 0 # 0", "v 1 0"), ("v #c 1 0 0", "v"),
            ("v#c 1 0 0", "v"), ("v 1 0 0#c\\", "v 1 0 0"),
            // 陰性対照: コメントの無い行は変わらない
            ("v 1 0 0", "v 1 0 0"), ("v 1 0", "v 1 0"),
            // `#` の直後に結合文字が付いても、`#` はコメントの始まり (`Character` では束ねられて
            // 見逃す。UTF-8 の 1 バイトで探す理由)
            ("v 1 0 0#\u{301}c", "v 1 0 0"),
        ])
    func commentsEndVertexLines(line: String, clean: String) {
        func parsed(_ vertex: String) -> ModelFile.Parsed {
            ModelFile.parse("v 0 0 0\n\(vertex)\nv 0 1 0\nf 1 2 3")
        }
        #expect(parsed(line) == parsed(clean), "\(line)")
    }

    @Test(
        "vt の行の # 以降はコメントで、欄に貼り付いていても落としてから欄を読む",
        arguments: [
            ("vt 0.5 0.5#c", "vt 0.5 0.5"), ("vt 0.5 0.5 # c", "vt 0.5 0.5"),
            ("vt 0.5 0.5 0.5#c", "vt 0.5 0.5 0.5"),
            // `u` だけの行は読める (v は 0)。コメントを欄に数えて読めない行にしない
            ("vt 0.5#c", "vt 0.5"), ("vt 0.5 # c", "vt 0.5"), ("vt 0.5#0.5 0.5", "vt 0.5"),
            ("vt 0.5 0.5#c 0.5", "vt 0.5 0.5"),
            // u が無ければ読めない行
            ("vt #c", "vt"), ("vt#c 0.5 0.5", "vt"), ("vt #c 0.5", "vt"),
            ("vt 0.5 0.5", "vt 0.5 0.5"),
            // `#` の直後に結合文字が付いても、`#` はコメントの始まり
            ("vt 0.5 0.5#\u{301}c", "vt 0.5 0.5"),
        ])
    func commentsEndTextureLines(line: String, clean: String) {
        func parsed(_ texture: String) -> ModelFile.Parsed {
            ModelFile.parse("v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0.25 0.75\n\(texture)\nf 1/2 2/2 3/2")
        }
        #expect(parsed(line) == parsed(clean), "\(line)")
    }

    @Test(
        "vn の行の # 以降はコメントで、欄に貼り付いていても落としてから欄を読む",
        arguments: [
            ("vn 0 1 0#x", "vn 0 1 0"), ("vn 0 1 0#", "vn 0 1 0"), ("vn 0 1 0 #x", "vn 0 1 0"),
            ("vn 0 1 0#x 9 9", "vn 0 1 0"), ("vn 0 1 0\t#x", "vn 0 1 0"),
            // 欄が 4 つ以上あれば読めない行 (#2566)。コメントの中の欄は数えない
            ("vn 0 1 0 1#x", "vn 0 1 0 1"), ("vn 0 1 0#x 1", "vn 0 1 0"),
            // コメントの手前に欄が足りなければ読めない行
            ("vn 0 1#x 0", "vn 0 1"), ("vn 0 1 # 0", "vn 0 1"), ("vn#x 0 1 0", "vn"),
            ("vn 0 1 0", "vn 0 1 0"),
            // `#` の直後に結合文字が付いても、`#` はコメントの始まり
            ("vn 0 1 0#\u{301}x", "vn 0 1 0"),
        ])
    func commentsEndNormalLines(line: String, clean: String) {
        func parsed(_ normal: String) -> ModelFile.Parsed {
            ModelFile.parse("v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 0 1\n\(normal)\nf 1//2 2//2 3//2")
        }
        #expect(parsed(line) == parsed(clean), "\(line)")
    }

    /// 約束 ([#2624]): 行の先頭の語に `#` が貼り付いた行 (`#Blender`) は、空白で区切ったコメント
    /// (`# Blender`) と同じコメントの行で、読み飛ばして数えない。
    ///
    /// [#2624]: https://github.com/mokume-metal/mokume/issues/2624
    @Test(
        "行の先頭に貼り付いた # もコメントで、読み飛ばして数えない",
        arguments: ["#Blender", "#", "# Blender", "  #Blender v 1 2 3", "#v 9 9 9"])
    func commentLinesAreNotSkippedLines(line: String) {
        let base = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3"
        #expect(ModelFile.parse("\(line)\n\(base)") == ModelFile.parse(base), "\(line)")
        #expect(ModelFile.parse("\(line)\n\(base)").skippedLines == 0, "\(line)")
    }

    /// Issue の例: 欄に貼り付いたコメントのある `v` を指す面が、行ごと読み飛ばされない。
    @Test("コメントが貼り付いた v・vt・vn の行を指す面は、読み飛ばされず三角形になる")
    func facesPointingAtCommentedLinesSurvive() {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0#c
            v 0 1 0
            vt 0.25 0.75#c
            vn 0 0 1#c
            f 1/1/1 2/1/1 3/1/1
            """)
        #expect(parsed.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        #expect(parsed.uvs == Array(repeating: SIMD2<Float>(0.25, 0.25), count: 3))
        #expect(parsed.normals == Array(repeating: SIMD3<Float>(0, 0, 1), count: 3))
        #expect(parsed.skippedLines == 0)
    }

    /// Windows 系の道具が書き出した OBJ は改行が `\r\n` である。**割れないと、先頭の
    /// `#` で全体がコメント扱いになり、頂点 0 のモデルが落ちも警告も無しに返る** —
    /// 唯一の手がかりである `skippedLines` も 0 なので、症状は「何も出ない」だけになる。
    @Test("改行が CRLF でも、LF と同じモデルになる")
    func carriageReturnsSeparateLinesToo() {
        let lf = ModelFile.parse(ModelFixture.pyramidText)
        // 割れていないことを「空と同じ」で見逃さないため、まず LF が読めている
        #expect(!lf.positions.isEmpty)

        let crlf = ModelFile.parse(
            ModelFixture.pyramidText.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(crlf == lf)

        // 単独の \r だけで改行する道具 (古い Mac 系) も同じ扱いにする
        let cr = ModelFile.parse(
            ModelFixture.pyramidText.replacingOccurrences(of: "\n", with: "\r"))
        #expect(cr == lf)
    }

    /// 約束: 読めない行は読み飛ばして数える。**OBJ の数は 10 進の綴りだけ** — Swift の
    /// `Float(String)` は 16 進 (`0x10`) を受け、NUL の手前で読み終える (`"3\0abc"` が 3) ので、
    /// それに任せると読めない行が数として置かれ、数えられない ([#2514])。`vt` の 2 つ目 (`v`) は
    /// 「無ければ 0」だが、書いてあって読めないものは無いのではない。読めない欄を飛ばして
    /// 詰めると、`vt abc 0.5` が u = 0.5 として置かれる。
    ///
    /// [#2514]: https://github.com/mokume-metal/mokume/issues/2514
    @Test(
        "v・vn・vt の数が 10 進の綴りでなければ、その行を置かずに読み飛ばして数える",
        arguments: [
            "v 0x10 0 0", "v 3\0abc 0 0", "v 1 2 3\0", "vn 0x1p0 0 0", "vt 0x1 0", "vt 0.5 0x1",
            "vt 0.5 1\0", "vt 0x1p-1 0", "vt abc 0.5", "v 1 abc 2 3", "vn 1 0 0x0",
            "v 1 2 +inf", "vt nan",
        ])
    func numbersAreReadAsDecimalOnly(line: String) {
        let base = """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0.25 0.75
            vn 0 0 1
            """
        let face = "f 1/1/1 2/1/1 3/1/1"
        let plain = ModelFile.parse(base + "\n" + face)
        // 面の**後ろ**に置いた読めない行は、形を変えずに数えられるだけ。前に置いても番号の枠は
        // 使うので、後ろの番号はずれない (下の `unreadablePositionLinesKeepTheirSlot`)
        let broken = ModelFile.parse(base + "\n" + face + "\n" + line)
        var expected = plain
        expected.skippedLines += 1
        #expect(broken == expected, "\(line.debugDescription)")
    }

    /// 約束 ([#2564]): **読めない行も番号の枠を 1 つ使う。** OBJ の番号は行の通し番号なので、
    /// 読めない `v`・`vt`・`vn` の行を詰めると、後ろの番号が 1 つずつずれ、面が別の頂点を指して
    /// 形が黙って変わる。数えるのは読めない行 1 つ分だけで変わらない。その行を指す角は、位置なら
    /// 面の行ごと読み飛ばして数え ([#2339])、`vt`・`vn` なら書いていない角と同じに読む ([#2349])。
    ///
    /// [#2564]: https://github.com/mokume-metal/mokume/issues/2564
    /// [#2339]: https://github.com/mokume-metal/mokume/issues/2339
    /// [#2349]: https://github.com/mokume-metal/mokume/issues/2349
    @Test(
        "面の前にある読めない v の行も番号の枠を使い、後ろの番号をずらさない",
        arguments: [
            "v 0x10 0 0", "v x 0 0", "v 1 2", "v nan 0 0", "v 1 2 +inf",
        ])
    func unreadablePositionLinesKeepTheirSlot(line: String) {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            \(line)
            v 1 0 0
            v 0 1 0
            f 1 3 4
            f -4 -2 -1
            f 1 2 3
            f 2 3 4
            """)
        // 1・3・4 番の頂点で組まれる (詰めて 1・2・3 番が別の形になることは無い)。
        // 負の番号も読めない行を数える (-4 = 1 番・-2 = 3 番・-1 = 4 番)
        let triangle = [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        #expect(parsed.positions == triangle + triangle, "\(line.debugDescription)")
        // 数えるのは、読めない `v` の行 1 つと、その行を指す面の行 2 つ (`f 1 2 3`・`f 2 3 4`)
        #expect(parsed.skippedLines == 3, "\(line.debugDescription)")
    }

    @Test("面の前にある読めない vt の行も番号の枠を使い、その行を指す角は書いていない角になる")
    func unreadableTextureLinesKeepTheirSlot() {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0.1 0.1
            vt 0x1 0
            vt 0.5 0.5
            vt 0.25
            f 1/1 2/2 3/3
            f 1/3 2/-4 3/4
            """)
        // 2 番は読めない行で、書いていない角と同じ。3 番は詰めずに 0.5, 0.5 を指す。
        // 2 面目: -4 は 1 番 (読める vt の行)。`vt 0.25` (4 番) は v を 0 として読む
        #expect(
            parsed.uvs == [
                SIMD2(0.1, 0.9), nil, SIMD2(0.5, 0.5),
                SIMD2(0.5, 0.5), SIMD2(0.1, 0.9), SIMD2(0.25, 1),
            ])
        // 読めない行 1 つだけ。角は数えない
        #expect(parsed.skippedLines == 1)
    }

    @Test("面の前にある読めない vn の行も番号の枠を使い、その行を指す角は書いていない角になる")
    func unreadableNormalLinesKeepTheirSlot() {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vn 0 1 0
            vn 0x1 0 0
            vn 1 0 0
            f 1//1 2//2 3//3
            """)
        // 2 番は読めない行で、向きを書いていない角と同じ (形から求めて両面)。
        // 3 番は詰めずに (1, 0, 0) を指す
        #expect(parsed.derivedNormals == [false, true, false])
        #expect(parsed.normals[0] == SIMD3(0, 1, 0))
        #expect(parsed.normals[1] == SIMD3(0, 0, 1))
        #expect(parsed.normals[2] == SIMD3(1, 0, 0))
        #expect(parsed.skippedLines == 1)
    }

    @Test("10 進の綴りなら、符号・小数点だけの始まり・指数を含めて読む")
    func decimalSpellingsStillRead() throws {
        let parsed = ModelFile.parse(
            """
            v 1.5 -2 3e1
            v +1 .5 5.
            v 0 1E-1 -0
            vt .5
            vt 1 -2.5e0
            f 1/1 2/2 3/1
            """)
        #expect(parsed.skippedLines == 0)
        #expect(parsed.positions == [SIMD3(1.5, -2, 30), SIMD3(1, 0.5, 5), SIMD3(0, 0.1, 0)])
        #expect(parsed.uvs == [SIMD2(0.5, 1), SIMD2(1, 3.5), SIMD2(0.5, 1)])
    }

    @Test("書かれた展開 (vt) を読み、読み飛ばした行に数えない")
    func textureCoordinatesAreRead() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 板 2 枚 = 三角形 2 枚 = 6 点。読み取り位置は点と同じ数だけ並ぶ
        #expect(parsed.positions.count == 6)
        #expect(parsed.uvs.count == 6)
        #expect(parsed.uvs.allSatisfy { $0 != nil }, "書いた展開が届いていない")
        // 読み飛ばしたのは mtllib の 1 行だけ (vt 4 行は読めている)
        #expect(parsed.skippedLines == 1)
    }

    @Test("読み取り位置の縦は裏返って乗る (OBJ は下から・この面は上から数える)")
    func textureCoordinatesFlipVertically() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 1 枚目の 3 点は vt 1・2・3。絵の下寄り (v = 0.8) を書いた角が、上寄り (0.2) に乗る
        #expect(parsed.uvs[0] == SIMD2(0.25, Float(1) - 0.8))
        #expect(parsed.uvs[1] == SIMD2(0.75, Float(1) - 0.8))
        #expect(parsed.uvs[2] == SIMD2(0.75, Float(1) - 0.1))
    }

    @Test("読み取り位置の番号も 1 から数え、負の番号は末尾から数える")
    func textureIndicesCountFromOneAndFromTheEnd() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 2 枚目は負の番号で書いてある (-4 / -2 / -1 = vt 1 / 3 / 4)
        #expect(parsed.uvs[3] == parsed.uvs[0])
        #expect(parsed.uvs[4] == parsed.uvs[2])
        #expect(parsed.uvs[5] == SIMD2(0.25, Float(1) - 0.1))
    }

    @Test("真ん中が空の角 (位置//向き) は、読み取り位置を持たない")
    func cornersWithoutTextureIndexAreEmpty() throws {
        let parsed = ModelFile.parse(ModelFixture.mixedUnwrapText)
        // 1 枚目は書いてある・2 枚目は `位置//向き` なので持たない
        #expect(parsed.uvs[0...2].allSatisfy { $0 != nil })
        #expect(parsed.uvs[3...5].allSatisfy { $0 == nil })
        // 向きのほうは 2 枚目も書かれているので、形から求めていない
        #expect(!parsed.derivedNormals.contains(true))
    }

    /// 約束 ([#2349]): 角の `vt` の番号が数として読めない・範囲の外なら、その角に `vt` を
    /// 書いていないのと同じに読む。面は残り、読み飛ばした行にも数えない。比べる側 (`1//1`) は
    /// 「書いていない」の書き方そのもの。**`vn` の側は [#2342] が直すまで比べない** — 向きを
    /// 書かない角が (0,0,1) へ倒れるのを、この比較が不具合ごと固定してしまう。
    ///
    /// [#2349]: https://github.com/mokume-metal/mokume/issues/2349
    /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
    @Test(
        "角の vt の番号が読めない・範囲の外なら、書いていない角と同じに読み、数えない",
        arguments: ["1/x/1", "1/99/1", "1/0/1", "1/-9/1", "1/1.5/1"])
    func unreadableTextureIndexReadsAsUnwritten(corner: String) {
        func parsed(_ first: String) -> ModelFile.Parsed {
            ModelFile.parse(
                """
                v 0 0 0
                v 1 0 0
                v 0 1 0
                vt 0.1 0.2
                vt 0.3 0.4
                vt 0.5 0.6
                vn 0 0 1
                f \(first) 2/2/1 3/3/1
                """)
        }
        let unwritten = parsed("1//1")
        let broken = parsed(corner)
        #expect(broken == unwritten, "\(corner)")
        // 面は残り (3 点)、1 つ目の角だけが読み取り位置を持たない
        #expect(broken.positions.count == 3)
        #expect(broken.uvs[0] == nil)
        #expect(broken.uvs[1] != nil && broken.uvs[2] != nil)
        #expect(broken.skippedLines == 0)
    }

    /// 約束 ([#2349] 条件 2): 角の `vn` の番号が読めない・範囲の外でも同じ。**書いていない角の
    /// 向きは形から求めて両面にする** ([#2342]) ので、読めない番号の角は (0, 0, 1) ではなく、
    /// 書いていない角と同じ求めた向きになる。向きを書いた角 (2・3 つ目) は書いた向きのまま。
    ///
    /// [#2349]: https://github.com/mokume-metal/mokume/issues/2349
    /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
    @Test(
        "角の vn の番号が読めない・範囲の外なら、書いていない角と同じに読み、数えない",
        arguments: ["1/1/x", "1/1/99", "1/1/0", "1/1/-9", "1/1/1.5"])
    func unreadableNormalIndexReadsAsUnwritten(corner: String) {
        func parsed(_ first: String) -> ModelFile.Parsed {
            ModelFile.parse(
                """
                v 0 0 0
                v 1 0 0
                v 0 1 0
                vt 0.1 0.2
                vt 0.3 0.4
                vt 0.5 0.6
                vn 0 1 0
                f \(first) 2/2/1 3/3/1
                """)
        }
        let unwritten = parsed("1/1")
        let broken = parsed(corner)
        #expect(broken == unwritten, "\(corner)")
        // 面は残り (3 点)、1 つ目の角だけが向きを書かず、形から求めて両面にする
        #expect(broken.positions.count == 3)
        #expect(broken.derivedNormals == [true, false, false])
        #expect(broken.normals[0] == SIMD3(0, 0, 1))
        #expect(broken.normals[1] == SIMD3(0, 1, 0) && broken.normals[2] == SIMD3(0, 1, 0))
        #expect(broken.uvs[0] != nil)
        #expect(broken.skippedLines == 0)
    }

    @Test("vt は u だけでも読め、3 つ目 (w) は無視する")
    func textureLinesToleratePartialAndExtraNumbers() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0.5
            vt 0.25 0.5 0.75
            vt 0.75 0.5
            f 1/1 2/2 3/3
            """)
        // v が無ければ 0 と読む (裏返して 1)
        #expect(parsed.uvs[0] == SIMD2(0.5, 1))
        // 3 つ目があっても手前の 2 つは正しい展開なので使う
        #expect(parsed.uvs[1] == SIMD2(0.25, 0.5))
        #expect(parsed.skippedLines == 0)
    }

    // MARK: - 向きを書いた面と書かない面が混ざる (#2342)

    /// #2337 の再現の形。B (1..3) は平面 x + z = 0 の三角形で、形から求めた向きは (1,0,1)/√2。
    /// A (4..6) は離れた所の正面向きの三角形で、B と点を共有しない。
    static let mixedNormalsVertices = """
        v 0 0 0
        v 1 0 -1
        v 0 1 0
        v -2 0 0
        v -1 0 0
        v -2 1 0
        vn 0 0 1
        vn 0.70710678 0 0.70710678
        """

    /// 約束: 面の向きは角ごとに扱う。**書かれていない角は形から求め、両面にする** ([#2342])。
    /// ファイルに `vn` が 1 つでもあると形から求めなかった頃は、`vn` の無い B が (0, 0, 1) へ
    /// 倒れていた ([#2337])。書いた面と点を共有しない面は、どの面にも `vn` が無いファイルと
    /// 1 ビットも違わない。範囲の外の `vn` 番号は書いていない角と同じに読む (#2349 の扱いのまま)。
    ///
    /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
    /// [#2337]: https://github.com/mokume-metal/mokume/issues/2337
    @Test(
        "vn のある面と無い面が混ざっても、無い面の向きは形から求め、その角だけが両面の印を持つ",
        arguments: ["f 1 2 3", "f 1//99 2//99 3//99"])
    func mixedNormalsAreDerivedPerCorner(unwritten: String) throws {
        let mixed = ModelFile.parse(Self.mixedNormalsVertices + "\nf 4//1 5//1 6//1\n" + unwritten)
        let none = ModelFile.parse(Self.mixedNormalsVertices + "\nf 4 5 6\nf 1 2 3")
        let expected = normalize(SIMD3<Float>(1, 0, 1))
        #expect(mixed.normals[3..<6].allSatisfy { distance($0, expected) < 1e-6 }, "\(mixed.normals)")
        #expect(Array(mixed.normals[3..<6]) == Array(none.normals[3..<6]))
        // 書いた A はそのまま
        #expect(mixed.normals[0..<3].allSatisfy { $0 == SIMD3(0, 0, 1) })
        #expect(mixed.derivedNormals == [false, false, false, true, true, true])
        #expect(none.derivedNormals == Array(repeating: true, count: 6))
    }

    /// 約束: 長さ 0 の向きは書いていないのと同じ (STL の `facet normal 0 0 0`・`normal(0, 0, 0)` と
    /// 同じ扱い)。書いたと読むと、形から求めず両面にもならず、向き 0 の頂点として光を受けない。
    @Test(
        "長さ 0 の vn は書いていない角として、形から求めて両面の印を付ける",
        arguments: [
            // (面の行, 両面の印)
            ("f 4//1 5//1 6//1\nf 1//3 2//3 3//3", [false, false, false, true, true, true]),
            ("f 1//3 2//3 3//3", [true, true, true]),
            ("f 1//2 2//3 3", [false, true, true]),
        ])
    func zeroLengthNormalsReadAsUnwritten(faces: String, marks: [Bool]) throws {
        let parsed = ModelFile.parse(Self.mixedNormalsVertices + "\nvn 0 0 0\n" + faces)
        #expect(parsed.derivedNormals == marks)
        let expected = normalize(SIMD3<Float>(1, 0, 1))
        let derivedB = zip(parsed.normals.suffix(3), marks.suffix(3)).filter { $0.1 }.map(\.0)
        #expect(derivedB.allSatisfy { distance($0, expected) < 1e-6 }, "\(parsed.normals)")
        #expect(parsed.normals.allSatisfy { length_squared($0) > 0.9 })
    }

    @Test("1 つの面の中で vn のある角と無い角が混ざっても、角ごとに決める")
    func normalsAreDecidedPerCornerWithinAFace() throws {
        let parsed = ModelFile.parse(Self.mixedNormalsVertices + "\nf 1//2 2 3")
        #expect(parsed.derivedNormals == [false, true, true])
        #expect(parsed.normals[0] == SIMD3(0.70710678, 0, 0.70710678))
        let expected = normalize(SIMD3<Float>(1, 0, 1))
        #expect(parsed.normals[1...].allSatisfy { distance($0, expected) < 1e-6 })
    }

    @Test("整えて巻き方を戻しても、両面の印は角に付いたまま動く", arguments: [nil, 60] as [Float?])
    func derivedMarksTravelWithTheirCorners(fitting: Float?) throws {
        // B の真ん中の角だけが向きを書いている
        let parsed = ModelFile.parse(Self.mixedNormalsVertices + "\nf 4//1 5//1 6//1\nf 1 2//2 3")
        let model = Model.make(name: "mixed.obj", parsed: parsed, fitting: fitting)
        // 整えると三角形ごとに 2 点目と 3 点目を入れ替える。印は位置・向きと一緒に動く
        let marks =
            fitting == nil
            ? [false, false, false, true, false, true] : [false, false, false, true, true, false]
        #expect(model.mesh.points.map(\.isDerivedNormal) == marks)
        let written = model.mesh.points[3...].filter { !$0.isDerivedNormal }
        #expect(written.count == 1)
        // 書いた向き (y が 0 なので縦の裏返しでも変わらない) がそのまま付いている
        #expect(written.first?.normal == SIMD3(0.70710678, 0, 0.70710678))
    }

    // MARK: - 整え方

    /// 面を作らずに整える。**GPU の無いところでも契約を確かめられる**ようにする —
    /// 整え方は描画とは関わりが無いので、面が要る検査にしてしまうと、いちばん確かめ
    /// たい規則が GPU の無い実行から丸ごと落ちる。
    private func normalized(fitting: Float?) throws -> Model {
        Model.make(
            name: "pyramid", parsed: try ModelFile.load(ModelFixture.pyramid),
            fitting: fitting)
    }

    @Test("整えると、中心が原点に来て面に合う大きさになる")
    func normalizingCentersAndFits() throws {
        // 面が 200 x 120 なら、短いほうの半分 = 60
        let model = try normalized(fitting: 60)

        // **頂点そのものから測る。** 報告している大きさだけを見ると、頂点が潰れて
        // いても報告の側が正しければ通ってしまう
        var lowest = SIMD3<Float>(repeating: .infinity)
        var highest = SIMD3<Float>(repeating: -.infinity)
        for point in model.mesh.points {
            lowest = simd_min(lowest, point.position)
            highest = simd_max(highest, point.position)
        }
        let measured = highest - lowest

        // いちばん長い辺が、面の短いほうの半分 (120 / 2 = 60)
        #expect(abs(max(measured.x, max(measured.y, measured.z)) - 60) < 0.001)
        #expect(abs((highest.x + lowest.x) / 2) < 0.001, "中心が原点に来ていない")
        #expect(abs((highest.y + lowest.y) / 2) < 0.001)
        #expect(model.center == .zero)
        #expect(abs(model.size.x - measured.x) < 0.001, "報告した大きさが頂点と食い違う")
        // **軸の比が変わらない。** 元は 2 x 1.6 x 2 なので、縮めても同じ比のまま
        #expect(abs(measured.x / measured.y - 2 / 1.6) < 0.001)
        #expect(abs(measured.x - measured.z) < 0.001)
    }

    @Test("整えないと、ファイルの座標がそのまま残る")
    func withoutNormalizingTheFileIsKept() throws {
        let model = try normalized(fitting: nil)
        // 元の四角錐は幅 2・高さ 1.6・奥行き 2 で、底面が y = 0
        #expect(abs(model.size.x - 2) < 0.001)
        #expect(abs(model.size.y - 1.6) < 0.001)
        #expect(abs(model.center.y - 0.8) < 0.001)
        // 縦軸の読み替えも整える側の仕事なので、ここでは起きていない
        #expect(model.mesh.points.contains { abs($0.position.y - 1.6) < 0.001 })
    }

    @Test("整えても、三角形の巻き方と面の向きが同じ側を指す")
    func normalizingKeepsTheWindingWithTheNormals() throws {
        // **縦だけの裏返しは鏡映である** (行列式が -1)。位置と向きの y を裏返すだけだと、
        // 3 点の巻き方から求まる向きが、持っている向きと逆を指すようになる。面の向きを
        // 書いていない形は、断片が巻き方で表裏を見分けて向きを裏返すので、それが見る側の
        // 面を裏から照らす (#1473)。四角錐は向きを書いていない形、板は書いた形である
        //
        // **整える前と比べる。** 巻き方が向きと揃っているかはファイルの書き方で決まる
        // (検体の四角錐は内向きに巻いてある) ので、整えてもそれが動かないことを見る
        func agreement(_ model: Model) -> [Bool] {
            let points = model.mesh.points
            return stride(from: 0, to: points.count - 2, by: 3).map { start in
                let (a, b, c) = (points[start], points[start + 1], points[start + 2])
                let wound = cross(b.position - a.position, c.position - a.position)
                return dot(wound, a.normal + b.normal + c.normal) > 0
            }
        }
        for path in [ModelFixture.pyramid, ModelFixture.unwrapped] {
            let parsed = try ModelFile.load(path)
            let raw = Model.make(name: path, parsed: parsed, fitting: nil)
            let fitted = Model.make(name: path, parsed: parsed, fitting: 60)
            let before = agreement(raw)
            #expect(!before.isEmpty)
            #expect(agreement(fitted) == before, "整えると、巻き方が向きと逆の側を指す (\(path))")
        }
    }

    @Test("整えると、縦軸がこの面の約束 (下向き) になる")
    func normalizingFlipsTheVerticalAxis() throws {
        let model = try normalized(fitting: 60)
        // モデルの頂点 (いちばん高いところ) は、この面では**いちばん小さい y**
        let lowest = model.mesh.points.map(\.position.y).min() ?? 0
        let highest = model.mesh.points.map(\.position.y).max() ?? 0
        let apex = model.mesh.points.filter { abs($0.position.x) < 0.001 && abs($0.position.z) < 0.001 }
        #expect(!apex.isEmpty, "尖った先が見つからない")
        #expect(apex.allSatisfy { abs($0.position.y - lowest) < 0.001 }, "先が下を向いている")
        #expect(highest > lowest)
    }

    @Test("書かれた展開があれば、それが読み取り位置になる")
    func writtenUnwrapBecomesTheReadingPosition() throws {
        let model = Model.make(
            name: "unwrapped", parsed: try ModelFile.load(ModelFixture.unwrapped),
            fitting: 60)
        // **囲みの箱から作る位置とは重ならない値**を書いてあるので、倒れていれば落ちる。
        // 整えると巻き方を戻すので、1 枚目の 3 点目 (vt 3) は 2 番目に並ぶ (#1473)
        #expect(model.mesh.points[0].uv == SIMD2(0.25, Float(1) - 0.8))
        #expect(model.mesh.points[1].uv == SIMD2(0.75, Float(1) - 0.1))
    }

    @Test("展開を持たないモデルは、囲みの箱の位置に倒れる")
    func modelsWithoutUnwrapFallBackToTheBoundingBox() throws {
        let model = try normalized(fitting: 60)
        // 四角錐の先 (ファイルで最も高いところ) は、絵の上端 (v = 0) を読む。
        // 底面の 4 点は絵の下端 (v = 1) で、横は囲みの箱の x を 0…1 に写した値
        let apex = model.mesh.points.filter {
            abs($0.position.x) < 0.001 && abs($0.position.z) < 0.001
        }
        #expect(!apex.isEmpty, "尖った先が見つからない")
        #expect(apex.allSatisfy { abs($0.uv.x - 0.5) < 0.001 && abs($0.uv.y) < 0.001 })
        let base = model.mesh.points.filter { $0.uv.y > 0.5 }
        #expect(!base.isEmpty)
        #expect(base.allSatisfy { abs($0.uv.y - 1) < 0.001 })
        #expect(base.allSatisfy { abs($0.uv.x) < 0.001 || abs($0.uv.x - 1) < 0.001 })
    }

    @Test("角ごとに混ざっていても、書かれた角だけが展開に従う")
    func writtenCornersWinPerCorner() throws {
        let model = Model.make(
            name: "mixed", parsed: try ModelFile.load(ModelFixture.mixedUnwrap),
            fitting: 60)
        // 整えると巻き方を戻すので、どちらの三角形も 2 点目と 3 点目が入れ替わって並ぶ (#1473)
        // 手前の 3 点は書かれた展開 (vt 1・3・2 の順)
        #expect(model.mesh.points[0].uv == SIMD2(0.25, Float(1) - 0.75))
        #expect(model.mesh.points[1].uv == SIMD2(0.75, Float(1) - 0.25))
        #expect(model.mesh.points[2].uv == SIMD2(0.75, Float(1) - 0.75))
        // 奥の 3 点は囲みの箱 (板は x が -1…1・y が 0…2 なので、角がそのまま四隅に来る)
        #expect(model.mesh.points[3].uv == SIMD2(0, 1))
        #expect(model.mesh.points[4].uv == SIMD2(0, 0))
        #expect(model.mesh.points[5].uv == SIMD2(1, 0))
    }

    @Test("読み取り位置は整え方に依らない")
    func readingPositionsDoNotDependOnNormalizing() throws {
        // **貼る絵の読み取り位置は形の座標ではない**ので、整えても倒れ先も含めて同じ値に
        // なる。整えたあとの座標から測っていた頃は、normalize: false でだけ絵が上下逆に
        // 乗っていた (#406)
        //
        // **角ごとに比べる。** 整えると巻き方を戻すので角の並びは変わる (#1473) が、読み取り
        // 位置は角に付いたまま動く。整えた角をファイルの座標へ引き戻し、同じ三角形の中で
        // 同じ位置にある角と比べる
        for path in [ModelFixture.pyramid, ModelFixture.unwrapped, ModelFixture.mixedUnwrap] {
            let parsed = try ModelFile.load(path)
            let fitted = Model.make(name: path, parsed: parsed, fitting: 60)
            let raw = Model.make(name: path, parsed: parsed, fitting: nil)
            #expect(fitted.mesh.points.count == raw.mesh.points.count)
            let scale = 60 / max(raw.size.x, max(raw.size.y, raw.size.z))
            for (index, point) in fitted.mesh.points.enumerated() {
                // 整えたのと逆の手順 (縦を戻し、縮めたぶん広げ、中心を戻す)
                let back =
                    SIMD3(point.position.x, -point.position.y, point.position.z) / scale
                    + raw.center
                let first = index / 3 * 3
                let same = raw.mesh.points[first..<(first + 3)].first {
                    distance($0.position, back) < 1e-4
                }
                #expect(same != nil, "整えた角が元の三角形に見つからない (\(path) の \(index) 番目)")
                #expect(
                    same?.uv == point.uv, "整え方で読み取り位置が動いた (\(path) の \(index) 番目)")
            }
        }
    }

    /// 面へ置いてから確かめるもの。**GPU を要する検査はこの入れ子に集める** — 条件を
    /// `@Test` ごとの注記で表すと 1 本ずつ付け忘れられる ([#336](https://github.com/mokume-metal/mokume/pull/336))
    /// ので、置き場所で表す。trait は入れ子へ継承されるので、ここに置いた検査には条件が必ず掛かる
    /// (付け忘れは `GPUGateTests` が原文から見つける)。
    @Suite(
        "面へ置く",
        .enabled(if: RenderDevice.isAvailable, "面を作るので GPU が要る")
    )
    struct OnCanvas {
        private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        // MARK: - 読み取り

        @Test("読めたが面が 1 つも無い状態が、読めなかった状態と区別できる")
        func anEmptyModelIsNotAFailure() throws {
            let canvas = try makeCanvas()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let empty = directory.appendingPathComponent("empty.obj")
            try "# 面が 1 つも無い\nv 0 0 0\n".write(to: empty, atomically: true, encoding: .utf8)

            // 読めた (投げない)。ただし面が無いことが読み取れる
            let model = try canvas.loadModel(empty.path)
            #expect(model.isEmpty)
            #expect(model.triangleCount == 0)

            // 読めなかったほうは投げる
            #expect(throws: ModelFailure.self) {
                _ = try canvas.loadModel("assets/missing-model.obj")
            }
        }

        @Test("対応していない形式は、そう分かる形で投げる")
        func unsupportedFormatsSayWhy() throws {
            let canvas = try makeCanvas()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            // STL は読めるようになった (#1966) ので、まだ読まない PLY を検体にする
            let other = directory.appendingPathComponent("thing.ply")
            try "ply".write(to: other, atomically: true, encoding: .utf8)

            do {
                _ = try canvas.loadModel(other.path)
                Issue.record("対応していない形式を読めてしまった")
            } catch {
                #expect(error == .unsupported(path: other.path, extensionName: "ply"))
            }
        }

        // MARK: - 置いたら見える

        @Test("読み込んで、そのまま置いた絵が画面に見える")
        func aLoadedModelIsVisible() throws {
            // **この 1 点が最重要。** 既定同士が噛み合っていないと、読み込みは成功して
            // いるのに数画素の点になり、しかも失敗ではないので原因に辿り着けない
            let canvas = try makeCanvas(width: 128, height: 128)
            let model = try canvas.loadModel(ModelFixture.pyramid)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.linear(red: 0.9, green: 0.7, blue: 0.4))
                canvas.push()
                canvas.translate(64, 64, 0)
                canvas.model(model)
                canvas.pop()
            }
            let image = try canvas.target.encodeForDisplay()
            var lit = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y].red > 20 { lit += 1 }
            }
            // 面の 1/50 より小さければ「読めているのに見えない」と同じこと
            #expect(lit > image.width * image.height / 50, "置いた絵が小さすぎる (\(lit) 画素)")
        }

        @Test("続けて置いても描く回数は増えない")
        func repeatedModelsCollapseIntoOneCall() throws {
            let canvas = try makeCanvas(width: 128, height: 128)
            let model = try canvas.loadModel(ModelFixture.pyramid)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                for index in 0..<8 {
                    canvas.push()
                    canvas.translate(20 + Float(index) * 12, 64, 0)
                    canvas.model(model)
                    canvas.pop()
                }
            }
            #expect(canvas.drawCallsInLastFrame == 1)
        }

        @Test("鏡映して置いた、面の向きの無いモデルも、見る側から光を受ける")
        func aMirroredModelWithDerivedNormalsCatchesTheLight() throws {
            // 形から求めた向きは、断片が「裏を向いている」と判定した面で裏返す。鏡映すると
            // 巻き方が裏返るので、表の巻き方を裏返さないと、見る側を向いた面が視線と逆の
            // 向きで光を受けて暗くなる (#1446)。四角錐は横の鏡映で自分に重なるので、
            // 鏡映して回した絵は逆に回した絵と同じになる
            //
            // **整えずに読む。** 整える経路の縦の裏返し (これも鏡映) は別の検査が見る
            // (#1473) ので、ここでは置き場所の鏡映だけを見る
            func picture(mirrored: Bool) throws -> DisplayImage {
                let canvas = try makeCanvas(width: 128, height: 128)
                let raw = try canvas.loadModel(ModelFixture.pyramid, normalize: false)
                try canvas.draw {
                    canvas.background(20)
                    canvas.directionalLight(255, 255, 255, 0, 0, -1)
                    canvas.noStroke()
                    canvas.fill(230, 60, 40)
                    canvas.translate(64, 64, 0)
                    if mirrored { canvas.scale(-1, 1, 1) }
                    canvas.rotateY(mirrored ? 0.6 : -0.6)
                    canvas.rotateX(0.5)
                    canvas.scale(30, 30, 30)
                    canvas.model(raw)
                }
                return try canvas.target.encodeForDisplay()
            }

            let mirrored = try picture(mirrored: true)
            let rotated = try picture(mirrored: false)
            let difference = PictureDifference.between(mirrored, rotated)
            #expect(difference.shapePixels > 1000, "モデルが写っていない (\(difference))")
            #expect(
                difference.fraction <= 0.02, "鏡映したモデルが逆に回したモデルと食い違う (\(difference))")
        }

        @Test(
            "整えて置いた四角錐は、面の向きを書いていなくても、書いたときと同じに光を受ける",
            arguments: [false, true])
        func aNormalizedModelWithDerivedNormalsMatchesWrittenNormals(reversedWinding: Bool)
            throws
        {
            // **整えると縦を裏返すので、巻き方が裏返る** (鏡映)。形から求めた向きは断片が
            // 巻き方で表裏を見分けて裏返すので、巻き方を戻さないと、見る側を向いた面が
            // 裏から光を受けて暗くなる (#1473)。書いた向きは裏返されないので、正しい絵の
            // 手本になる。検体の四角錐は内向きに巻いてあるので、外向きに巻き直したものと
            // 両方で見る (形から求めた向きは両面なので、どちらの巻き方でも同じ絵になる)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            func written(_ text: String, as name: String) throws -> String {
                let url = directory.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                return url.path
            }

            let outward = Self.reversingWinding(of: ModelFixture.pyramidText)
            let derived = try written(
                reversedWinding ? ModelFixture.pyramidText : outward, as: "derived.obj")
            // **書く向きは、外向きに巻いた形から求まる向きそのもの**にする。値が同じなので、
            // 2 枚の違いは「向きを裏から受けているか」だけになる
            let writtenNormals = try written(Self.writingDerivedNormals(of: outward), as: "written.obj")

            func picture(_ path: String) throws -> DisplayImage {
                let canvas = try makeCanvas(width: 128, height: 128)
                let model = try canvas.loadModel(path)
                try canvas.draw {
                    canvas.background(20)
                    canvas.directionalLight(255, 255, 255, 0, 0, -1)
                    canvas.noStroke()
                    canvas.fill(230, 60, 40)
                    canvas.translate(64, 64, 0)
                    canvas.rotateY(-0.6)
                    canvas.rotateX(0.5)
                    canvas.model(model)
                }
                return try canvas.target.encodeForDisplay()
            }

            let reference = try picture(writtenNormals)
            // 手本が暗ければ、2 枚が揃って暗くても一致してしまう。光を向けた面が明るいことを先に見る
            var brightest = 0
            for y in 0..<reference.height {
                for x in 0..<reference.width { brightest = max(brightest, Int(reference[x, y].red)) }
            }
            #expect(brightest > 150, "書いた向きの四角錐が光を受けていない (赤の最大 \(brightest))")

            let difference = PictureDifference.between(try picture(derived), reference)
            #expect(difference.shapePixels > 1000, "モデルが写っていない (\(difference))")
            #expect(
                difference.fraction <= 0.02,
                "向きを書いていない四角錐が、書いた四角錐と違う光り方をする (\(difference))")
        }

        /// `f` の行の角を逆に並べ、巻き方を裏返す。
        private static func reversingWinding(of text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.first == "f" else { return String(line) }
                return (["f"] + fields.dropFirst().reversed()).joined(separator: " ")
            }.joined(separator: "\n")
        }

        /// 形から求まる向きを書き込んだ OBJ。**三角形ごとにばらして**書く — 角ごとに向きを
        /// 持たせれば、点を共有していなくても同じ向きの並びになる。
        private static func writingDerivedNormals(of text: String) -> String {
            let parsed = ModelFile.parse(text)
            var lines: [String] = []
            for (position, normal) in zip(parsed.positions, parsed.normals) {
                lines.append("v \(position.x) \(position.y) \(position.z)")
                lines.append("vn \(normal.x) \(normal.y) \(normal.z)")
            }
            for first in stride(from: 1, through: parsed.positions.count - 2, by: 3) {
                lines.append(
                    "f \(first)//\(first) \(first + 1)//\(first + 1) \(first + 2)//\(first + 2)")
            }
            return lines.joined(separator: "\n")
        }

        // MARK: - 向きを書いた面と書かない面が混ざる (#2342)

        /// 塗りの頂点が通る 3 つの経路。どれも同じ点から頂点を作る。
        enum FillRoute: String, CaseIterable, Sendable {
            /// 保持する形を記録している間 (置き場所を頂点へ焼く)。
            case recording
            /// 溜め場 (GPU の控えを持たない — 予算 0)。
            case staging
            /// GPU の控え (#1749)。
            case retained
        }

        /// 約束: 両面の印は角ごとに頂点へ届く ([#2342])。モデル単位の 1 つの印で決めていた頃は、
        /// 混ざったモデルの頂点がどれも片面 (0) だった。
        ///
        /// [#2342]: https://github.com/mokume-metal/mokume/issues/2342
        @Test("混ざったモデルを置くと、書かれていなかった角の頂点だけが両面の印を持つ", arguments: FillRoute.allCases)
        func derivedMarksReachTheVerticesPerCorner(_ route: FillRoute) throws {
            let canvas = try makeCanvas()
            let model = Model.make(
                name: "mixed.obj",
                parsed: ModelFile.parse(ModelTests.mixedNormalsVertices + "\nf 4//1 5//1 6//1\nf 1 2//2 3"),
                fitting: nil)
            let expected: [Float] = [0, 0, 0, 1, 0, 1]
            var marks: [Float] = []
            switch route {
            case .recording:
                let shape = canvas.createShape {
                    canvas.noStroke()
                    canvas.model(model)
                }
                marks = shape.solidVertices.map(\.normal.w)
            case .staging, .retained:
                if route == .staging { canvas.modelFills.budget = 0 }
                try canvas.draw {
                    canvas.noStroke()
                    canvas.model(model)
                    if route == .staging {
                        marks = canvas.solidVertices.map(\.normal.w)
                    } else if let geometry = canvas.openSolid?.fillGeometry {
                        let vertices = UnsafeBufferPointer(
                            start: geometry.buffer.contents().assumingMemoryBound(to: SolidVertex.self),
                            count: geometry.count)
                        marks = vertices.map(\.normal.w)
                    }
                }
            }
            #expect(marks == expected, "\(route)")
        }

        /// 混ざったファイルの B の明るさが、B に正しい向きを書いたときと、どの面も向きを書かない
        /// ときと揃う ([#2337]・[#2338] の再現と同じ構図)。光は (-1, 0, -1) へ進み、向き (1,0,1)/√2
        /// の B に真正面から当たる。
        ///
        /// [#2337]: https://github.com/mokume-metal/mokume/issues/2337
        /// [#2338]: https://github.com/mokume-metal/mokume/issues/2338
        private func brightnessOfB(
            _ contents: Data, as name: String, light: SIMD3<Float> = SIMD3(-1, 0, -1)
        ) throws -> Float {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url)

            let canvas = try makeCanvas(width: 200, height: 200)
            let model = try canvas.loadModel(url.path, normalize: false)
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.directionalLight(255, 255, 255, light.x, light.y, light.z)
                canvas.translate(100, 100, 0)
                canvas.scale(60, 60, 60)
                canvas.model(model)
            }
            let image = try canvas.target.readPixels()
            var sum: Float = 0
            var count = 0
            // B の内側 (x + z = 0 の三角形を正面から見た所)
            for y in 106..<125 {
                for x in 106..<118 {
                    let color = image[x, y]
                    sum += (color.red + color.green + color.blue) / 3
                    count += 1
                }
            }
            return sum / Float(count)
        }

        @Test("OBJ で vn のある面と無い面が混ざっても、無い面は形から求めた向きで光を受ける")
        func mixedOBJNormalsCatchTheLightLikeDerived() throws {
            let vertices = ModelTests.mixedNormalsVertices + "\n"
            let mixed = try brightnessOfB(
                Data((vertices + "f 4//1 5//1 6//1\nf 1 2 3\n").utf8), as: "mixed.obj")
            let written = try brightnessOfB(
                Data((vertices + "f 4//1 5//1 6//1\nf 1//2 2//2 3//2\n").utf8), as: "written.obj")
            let none = try brightnessOfB(Data((vertices + "f 4 5 6\nf 1 2 3\n").utf8), as: "none.obj")
            // 物差し: 正しい向きなら真正面から光を受ける
            #expect(written > 0.9, "B に光が当たっていない (\(written))")
            #expect(abs(mixed - written) <= 0.05, "混ざった \(mixed)・書いた \(written)")
            #expect(abs(mixed - none) <= 0.05, "混ざった \(mixed)・どれも無い \(none)")
        }

        @Test("STL で向き 0 0 0 の面は、向きを書いた面と混ざっても両面として光を受ける")
        func mixedSTLZeroNormalsStayTwoSided() throws {
            // B は見る側と逆に巻き、向きを 0 0 0 にする。両面なら裏から見ても光を受ける
            let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, -1), c = SIMD3<Float>(0, 1, 0)
            let reversedB = ModelFixture.Facet(normal: .zero, corners: [a, c, b])
            let corners: [SIMD3<Float>] = [SIMD3(-2, 0, 0), SIMD3(-1, 0, 0), SIMD3(-2, 1, 0)]
            let mixed = try brightnessOfB(
                ModelFixture.binarySTL([reversedB, .init(normal: SIMD3(0, 0, 1), corners: corners)]),
                as: "mixed.stl")
            let allZero = try brightnessOfB(
                ModelFixture.binarySTL([reversedB, .init(normal: .zero, corners: corners)]),
                as: "zero.stl")
            #expect(allZero > 0.9, "どの面も 0 0 0 の B に光が当たっていない (\(allZero))")
            #expect(abs(mixed - allZero) <= 0.05, "混ざった \(mixed)・どれも 0 0 0 \(allZero)")
        }

        /// OBJ の `vn 0 0 0` も、STL の `facet normal 0 0 0` と同じく書いていない向きとして形から
        /// 求め、両面にする。書いたと読むと、向き 0 の頂点は光を受けず塗りの色そのまま (1.0) に
        /// なる。**光は斜め (-1, 0, 0) から当てる** — 正面から当てると、光を受けた明るさも
        /// ほぼ 1 で見分けが付かない。B は見る側と逆に巻くので、両面でなければ裏から見て暗い。
        @Test(
            "OBJ で長さ 0 の vn を書いた面は、形から求めた向きで両面として光を受ける",
            arguments: [false, true])
        func zeroLengthOBJNormalsAreDerivedAndTwoSided(mixed: Bool) throws {
            let vertices = ModelTests.mixedNormalsVertices + "\nvn 0 0 0\n"
            let a = mixed ? "f 4//1 5//1 6//1\n" : ""
            let light = SIMD3<Float>(-1, 0, 0)
            let zero = try brightnessOfB(
                Data((vertices + a + "f 1//3 3//3 2//3\n").utf8), as: "zero-vn.obj", light: light)
            let none = try brightnessOfB(
                Data((vertices + a + "f 1 3 2\n").utf8), as: "none.obj", light: light)
            // 物差し: 向き (1,0,1)/√2 に 45° で当たる明るさ (cos 45° ≈ 0.707)。1 なら光を受けていない
            #expect(abs(none - 0.707) <= 0.05, "向きを書いていない B の明るさ (\(none))")
            #expect(abs(zero - none) <= 0.05, "vn 0 0 0 \(zero)・書いていない \(none)")
        }

        // MARK: - 別の Canvas で読んだモデル (#1846)

        /// 本体と描き場所 (`createGraphics`) で別々に読んだモデルの置き方。
        enum ForeignModelScene: String, CaseIterable, Sendable {
            /// 塗りだけ。同じ描き切りで頂点を共有する表の鍵を見る。
            case fill
            /// 線だけ。フレームをまたぐ稜線の控えの鍵を見る。
            case stroke
            /// 影を落とす。焼き直すかの指紋を見る。
            case shadow
        }

        /// `pg` の上で、前のフレームに `other` を置いてから `own` を置いたフレームの絵。
        /// `other` が無ければ、`own` だけを初めて置いたフレームの絵 (物差し)。
        private func pictureOfOwn(
            _ scene: ForeignModelScene, on pg: Canvas, own: Model, after other: Model?
        ) throws -> [UInt8] {
            func place(_ model: Model, at x: Float) {
                pg.push()
                pg.translate(x, 48, 0)
                pg.scale(0.6, 0.6, 0.6)
                pg.model(model)
                pg.pop()
            }
            func frame(_ body: () -> Void) throws {
                try pg.draw {
                    pg.background(.linear(red: 0, green: 0, blue: 0))
                    switch scene {
                    case .fill:
                        pg.noStroke()
                        pg.fill(.linear(red: 1, green: 1, blue: 1))
                    case .stroke:
                        pg.noFill()
                        pg.stroke(.linear(red: 1, green: 1, blue: 1))
                    case .shadow:
                        pg.directionalLight(.linear(red: 0.9, green: 0.9, blue: 0.9), -0.6, 0.6, -0.5)
                        pg.shadows(true)
                        pg.noStroke()
                        pg.fill(.linear(red: 0.8, green: 0.8, blue: 0.8))
                        // 影を受ける床
                        pg.push()
                        pg.translate(48, 48, -30)
                        pg.plane(90, 90)
                        pg.pop()
                    }
                    body()
                }
            }
            if let other {
                try frame { place(other, at: 48) }
            }
            try frame {
                // 塗りは同じ描き切りの中で共有するので、画面の外にも置いておく
                if let other, scene == .fill { place(other, at: 10_000) }
                place(own, at: 48)
            }
            return try pg.target.encodeForDisplay().bytes
        }

        /// 頂点を傾けた四角錐。**頂点と面の数は ``ModelFixture/pyramid`` と同じ**で、形だけが
        /// 違う — 数が違うと、影の指紋 (頂点の数を混ぜる) では取り違えが表に出ない。
        private static let leaningPyramid: String = {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-leaning-pyramid.obj")
            let text = ModelFixture.pyramidText.replacingOccurrences(
                of: "v 0.0 1.6 0.0", with: "v 0.9 1.6 0.9")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }()

        @Test(
            "本体で読んだモデルを先に置いても、描き場所で読んだモデルの絵は変わらない",
            arguments: ForeignModelScene.allCases)
        func aModelFromAnotherCanvasDoesNotStandInForOwn(_ scene: ForeignModelScene) throws {
            let main = try makeCanvas()
            let fromMain = try main.loadModel(ModelFixture.pyramid)

            let pg = try main.createGraphics(96, 96)
            let own = try pg.loadModel(Self.leaningPyramid)
            #expect(own.triangleCount == fromMain.triangleCount)
            let placed = try pictureOfOwn(scene, on: pg, own: own, after: fromMain)

            // 物差し: 別の描き場所で、同じファイルを読んで初めて置いた絵
            let fresh = try main.createGraphics(96, 96)
            let reference = try pictureOfOwn(
                scene, on: fresh, own: try fresh.loadModel(Self.leaningPyramid), after: nil)

            // 物差しに形が写っていること。**不透明度の桁は見ない** — 背景が不透明なので常に 255
            let drawn = stride(from: 0, to: reference.count, by: 4).filter {
                reference[$0] > 16 || reference[$0 + 1] > 16 || reference[$0 + 2] > 16
            }.count
            #expect(drawn > 20, "物差しに形が写っていない — 比べる前提が崩れている (\(drawn) 画素)")
            let differing = stride(from: 0, to: placed.count, by: 4).filter {
                placed[$0..<($0 + 4)] != reference[$0..<($0 + 4)]
            }.count
            #expect(differing == 0, "描き場所のモデルが、本体のモデルの形で描かれた (\(differing) 画素)")
        }

        @Test("別々の Canvas で読んだモデルは、同じ番号を持たず等しくない")
        func modelsReadOnDifferentCanvasesAreDistinct() throws {
            let main = try makeCanvas()
            let pg = try main.createGraphics(32, 32)
            let fromMain = try main.loadModel(ModelFixture.pyramid)
            let own = try pg.loadModel(ModelFixture.pyramid)
            #expect(fromMain.identity != own.identity)
            #expect(fromMain != own, "違う Canvas で読んだ別のモデルが等しいと言われた")
            // 同じ Canvas の控えから返るものは同じ
            #expect(try pg.loadModel(ModelFixture.pyramid) == own)
        }

        @Test("並行して番号を取っても重ならない")
        func identitiesNeverRepeatUnderConcurrency() async {
            let drawn = await withTaskGroup(of: [Int].self) { group in
                for _ in 0..<8 {
                    group.addTask { (0..<1_000).map { _ in Model.nextIdentity() } }
                }
                var all: [Int] = []
                for await part in group { all += part }
                return all
            }
            #expect(drawn.count == 8_000)
            #expect(Set(drawn).count == drawn.count)
        }

        // MARK: - 読み直さない

        @Test("同じ名前・同じ整え方なら読み直さない")
        func theSameFileIsNotReadTwice() throws {
            let canvas = try makeCanvas()
            let first = try canvas.loadModel(ModelFixture.pyramid)
            let second = try canvas.loadModel(ModelFixture.pyramid)
            #expect(first == second, "同じ読み込みが返っていない")

            // 整え方が違えば別のもの
            let raw = try canvas.loadModel(ModelFixture.pyramid, normalize: false)
            #expect(raw != first)
            #expect(canvas.modelCache.count == 2)
        }

        /// 四角錐を別々の場所へ `count` 個書き出す。**連番の OBJ の形** (名前を組み立てて読む)。
        private func writtenPyramids(_ count: Int) throws -> [String] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-sequence-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return try (0..<count).map { index in
                let url = directory.appendingPathComponent("wave-\(index).obj")
                try ModelFixture.pyramidText.write(to: url, atomically: true, encoding: .utf8)
                return url.path
            }
        }

        private func removeDirectory(of paths: [String]) {
            guard let first = paths.first else { return }
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: first).deletingLastPathComponent())
        }

        /// 控えを引いて、在るかだけを返す。**真偽値にしてから `#expect` へ渡す** (中身を渡すと、
        /// 失敗したときの説明に点が全部並ぶ)。
        private func remembers(_ canvas: Canvas, _ path: String) -> Bool {
            canvas.modelCache[ModelRequest(path: path, normalize: true)] != nil
        }

        @Test("予算を超えるだけ別々のモデルを読んでも、控えの合計は予算以下に収まり、最後に読んだものは残る")
        func theModelCacheDropsTheOldestUntilItFits() throws {
            let paths = try writtenPyramids(10)
            defer { removeDirectory(of: paths) }

            let canvas = try makeCanvas()
            // 面の控えの予算は、画像とは別の 64 MiB (#1593 の決定)
            #expect(canvas.modelCache.budget == Canvas.modelCacheBudget)
            #expect(Canvas.modelCacheBudget == 64 << 20)

            // 予算は検査から絞る。64 MiB を超えるだけのモデルを書き出すと、解釈に時間が掛かる
            let each = Canvas.modelCacheWeight(try canvas.loadModel(paths[0]))
            canvas.modelCache.budget = each * 3
            for path in paths.dropFirst() { _ = try canvas.loadModel(path) }

            #expect(
                canvas.modelCache.total <= canvas.modelCache.budget,
                """
                \(paths.count) 個読んだあとの控えが \(canvas.modelCache.total) バイトで、
                予算 \(canvas.modelCache.budget) を超えている。

                動きを書き出した連番の OBJ を 1 枚ずつ読むと、読んだモデルが全部残る (#1593)。
                """)
            #expect(canvas.modelCache.count == 3)
            #expect(remembers(canvas, paths.last!), "最後に読んだものが捨てられた")
            #expect(!remembers(canvas, paths[0]), "いちばん古いものが残っている")
            #expect(canvas.modelCache.made == paths.count)
        }

        @Test(
            "途中で読み直したモデルは捨てられない (loadModel と requestModel の両方)",
            arguments: [false, true])
        func rereadModelsAreKept(throughRequest: Bool) async throws {
            let paths = try writtenPyramids(10)
            defer { removeDirectory(of: paths) }

            let canvas = try makeCanvas()
            func read(_ path: String) async throws -> Model {
                if throughRequest { return try await canvas.requestModel(path) }
                return try canvas.loadModel(path)
            }
            let kept = try await read(paths[0])
            canvas.modelCache.budget = Canvas.modelCacheWeight(kept) * 3
            for path in paths.dropFirst() {
                _ = try await read(paths[0])
                _ = try await read(path)
            }

            #expect(canvas.modelCache.total <= canvas.modelCache.budget)
            // 1 回おきに読み直した 1 つ目は、1 度しか解釈していない
            #expect(
                canvas.modelCache.made == paths.count,
                "読み直したモデルが捨てられ、解釈し直された (入れた順に捨てている)")
            #expect(try await read(paths[0]) == kept)
        }

        @Test("線を引いたモデルの稜線も、モデルを読み進めるうちに稜線の控えの予算を超えない")
        func modelEdgesStayWithinTheBudget() throws {
            let paths = try writtenPyramids(10)
            defer { removeDirectory(of: paths) }

            let canvas = try makeCanvas()
            // モデルの控えから追い出したモデルを読み直すと番号が変わり、前の番号の稜線は
            // 二度と当たらない。稜線の控えが件数で切ると、それが予算の外に残る
            let first = try canvas.loadModel(paths[0])
            canvas.modelCache.budget = Canvas.modelCacheWeight(first) * 3
            var models = [first]
            for path in paths.dropFirst() { models.append(try canvas.loadModel(path)) }
            try canvas.draw {
                canvas.stroke(LinearRGBA.linear(red: 1, green: 1, blue: 1))
                canvas.model(first)
            }
            let each = try #require(canvas.solidEdges[.model(identity: first.identity)])
            canvas.solidEdges.budget = Canvas.solidEdgesWeight(each) * 3
            for model in models.dropFirst() {
                try canvas.draw {
                    canvas.stroke(LinearRGBA.linear(red: 1, green: 1, blue: 1))
                    canvas.model(model)
                }
            }

            // 控えが名乗る合計ではなく、残っている稜線の重さを数え直す
            let kept = models.compactMap { canvas.solidEdges[.model(identity: $0.identity)] }
            let bytes = kept.map(Canvas.solidEdgesWeight).reduce(0, +)
            #expect(
                bytes <= canvas.solidEdges.budget,
                "モデル \(kept.count) 個分の稜線 (\(bytes) バイト) が、予算 \(canvas.solidEdges.budget) を超えて残っている")
            #expect(canvas.solidEdges[.model(identity: models.last!.identity)] != nil)
        }

        @Test("1 つで予算を超えるモデルも読めて控えに残り、読み直しても解釈し直さない")
        func anOversizedModelIsKept() throws {
            let paths = try writtenPyramids(2)
            defer { removeDirectory(of: paths) }

            let canvas = try makeCanvas()
            // どのモデルも 1 つで予算を超える
            canvas.modelCache.budget = 1
            _ = try canvas.loadModel(paths[0])
            let huge = try canvas.loadModel(paths[1])
            #expect(canvas.modelCache.count == 1, "予算を超えたのに、前のモデルを捨てていない")

            let again = try canvas.loadModel(paths[1])
            #expect(again == huge)
            #expect(canvas.modelCache.made == 2, "控えに残したはずのモデルを解釈し直した")
        }
    }
}
