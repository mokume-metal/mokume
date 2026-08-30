// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 検査に使うモデルのファイル。
///
/// **中身を Swift の文字列で持ち、要るときに書き出す。** リポジトリにモデルの
/// ファイルは置かない (置き場の原則は `scripts/check-no-binaries.sh` が守る) し、
/// 文字列で持てば「どんな中身を読ませているか」が検査のすぐ隣で読める。
enum ModelFixture {
    /// 四角錐。**面の向きは書いていない** (読み込む側が形から求める)。
    ///
    /// 縦軸は上向き (モデルのよくある約束) で、底面は `y = 0` にある。材質・物体の
    /// 区切り・なめらかさの指定を混ぜてあるので、読み飛ばしの数も確かめられる。
    static let pyramidText = """
        # 検査に使う四角錐
        mtllib pyramid.mtl
        o pyramid
        v -1.0 0.0 -1.0
        v 1.0 0.0 -1.0
        v 1.0 0.0 1.0
        v -1.0 0.0 1.0
        v 0.0 1.6 0.0
        s off
        usemtl stone
        f 1 2 5
        f 2 3 5
        f 3 4 5
        f 4 1 5
        f 4 3 2 1
        """

    /// 書き出した四角錐の場所。**同じ場所へ 1 度だけ書く**ので、読み直しの検査でも
    /// 同じ名前を指せる。
    static let pyramid: String = written(pyramidText, as: "pyramid.obj")

    /// 作者が展開を書いた板。**囲みの箱から作る位置とは重ならない値**を選んである —
    /// 重なっていると、`vt` を読めているのか倒れているのかが検査から見分けられない。
    ///
    /// 縦は絵の下から上へ数える OBJ の約束で書いてあるので、読んだ側では上下が
    /// 裏返って乗る。負の番号と `mtllib` (読み飛ばす行) を混ぜてある。
    static let unwrappedText = """
        # 展開を書いた板
        mtllib board.mtl
        v -1 0 0
        v 1 0 0
        v 1 2 0
        v -1 2 0
        vt 0.25 0.8
        vt 0.75 0.8
        vt 0.75 0.1
        vt 0.25 0.1
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1
        f 1/-4/1 3/-2/1 4/-1/1
        """

    /// 書き出した板の場所。
    static let unwrapped: String = written(unwrappedText, as: "unwrapped.obj")

    /// **角ごとに展開があったり無かったりする板。** 手前の三角形だけが `vt` を持ち、
    /// 奥の三角形は `位置//向き` で書いてある (真ん中が空 = 読み取り位置を持たない)。
    static let mixedUnwrapText = """
        # 半分だけ展開を書いた板
        v -1 0 0
        v 1 0 0
        v 1 2 0
        v -1 2 0
        vt 0.25 0.75
        vt 0.75 0.75
        vt 0.75 0.25
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1
        f 1//1 3//1 4//1
        """

    /// 書き出した「半分だけ展開を書いた板」の場所。
    static let mixedUnwrap: String = written(mixedUnwrapText, as: "mixed-unwrap.obj")

    /// 検体を決まった場所へ 1 度だけ書き出す。
    private static func written(_ text: String, as name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-fixtures", isDirectory: true)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
