// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 画像を読む・作るときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum ImageFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。
    case notFound(path: String, searched: [String])
    /// 見つかったが、画像として読めない。
    case undecodable(path: String)
    /// GPU 側へ置けない — 読めたが置き場が足りない、あるいは面の上限より大きい。
    case unplaceable(width: Int, height: Int)
}

extension ImageFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える。** 資材が読めない不具合は、描画側が
            // 正しく動いているのに絵にならない形で現れるので、実装を疑うと当たりが
            // 外れる。宣言の抜けを先に確かめられるようにする
            return """
                「\(path)」が見つかりません。
                探した場所:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                置いたはずなら、パッケージの宣言に資材の置き場が書かれているか確かめてください \
                (`.executableTarget(..., resources: [.copy("assets")])`)。\
                宣言が無いとビルドは静かに通り、実行時に読めないだけになります。
                """
        case .undecodable(let path):
            return "「\(path)」は画像として読めません。形式が対応しているか確かめてください"
        case .unplaceable(let width, let height):
            return """
                \(width)x\(height) の画像を GPU 側へ置けません。
                一辺は \(RenderDevice.maxTextureSide) 画素までです — それより小さいか確かめてください
                """
        }
    }
}
