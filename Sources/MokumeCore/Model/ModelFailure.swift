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
    /// 見つかったが、その形式として読めない。OBJ なら文字 (UTF-8) として読めない、STL なら
    /// 文字の STL としてもバイナリの STL としても読めない (壊れている・途中で切れている・空)。
    case unreadable(path: String)
    /// 対応していない形式。説明に、読める形式の一覧が載る。
    case unsupported(path: String, extensionName: String)
}

extension ModelFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える** (``ImageFailure`` と同じ理由)。
            return """
                Cannot find "\(path)".
                Looked in:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                If you did put it there, check that the package declares where its resources are \
                (`.executableTarget(..., resources: [.copy("assets")])`). \
                Without that declaration the build still passes quietly, and the file just cannot \
                be read at run time
                """
        case .unreadable(let path):
            // **形式ごとに言い分ける。** バイナリの STL に「文字として読めない」と言うと、
            // 読み手を取り違えたように読める
            switch ModelFile.Format(path: path) {
            case .stl:
                return """
                    "\(path)" cannot be read as STL (neither ASCII nor binary). \
                    Check whether it is damaged or cut short
                    """
            case .obj, nil:
                return "\"\(path)\" cannot be read as text. Check whether it is damaged"
            }
        case .unsupported(let path, let extensionName):
            // **一覧は読み手の選び方と同じ所から引く** (``ModelFile/Format``)。別々に書くと、
            // 形式を足したときに説明だけが古いまま残る
            let readable = ModelFile.Format.allCases.map(\.displayName).joined(separator: ", ")
            return """
                The format of "\(path)" (.\(extensionName)) is not supported. \
                Readable formats: \(readable)
                """
        }
    }
}
