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
    static let pyramid: String = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-fixtures", isDirectory: true)
            .appendingPathComponent("pyramid.obj")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? pyramidText.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }()
}
