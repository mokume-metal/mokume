// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// モデルを読むときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。
///
/// **「読めなかった」と「読めたが面が無い」は別である。** 後者は失敗として投げず、
/// 置いたときに知らせる — 投げてしまうと、利用者は読み込みの側を直そうとして、
/// 実際には空のファイルを渡しているという事実に辿り着けない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum ModelFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。
    case notFound(path: String, searched: [String])
    /// 見つかったが、文字として読めない。
    case unreadable(path: String)
    /// 対応していない形式。
    case unsupported(path: String, extensionName: String)
}

extension ModelFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える** (``ImageFailure`` と同じ理由)。
            return """
                「\(path)」が見つかりません。
                探した場所:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                置いたはずなら、パッケージの宣言に資材の置き場が書かれているか確かめてください \
                (`.executableTarget(..., resources: [.copy("assets")])`)。\
                宣言が無いとビルドは静かに通り、実行時に読めないだけになります。
                """
        case .unreadable(let path):
            return "「\(path)」を文字として読めません。壊れていないか確かめてください"
        case .unsupported(let path, let extensionName):
            return """
                「\(path)」の形式 (.\(extensionName)) には対応していません。\
                いまは OBJ (.obj) だけを読みます。
                """
        }
    }
}
