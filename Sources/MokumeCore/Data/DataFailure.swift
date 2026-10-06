// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 文字列・表・JSON・XML・SVG を読む・書くときに起こりうる失敗。
///
/// SVG (``Sketch/loadShape(_:)``) は XML の文字なので同じ型で運ぶ。XML として壊れているときと、
/// 根が `<svg>` でないときが ``malformed(path:line:reason:)`` になる。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みと書き出しは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。読んだ表から値を取り出す口 (``TableRow/getFloat(_:)-(String)``
/// など) は投げない。
///
/// **壊れたファイルは、壊れたまま読まない。** 閉じない引用符や列の数が合わない行を、
/// 詰めたり捨てたりして読み進めると、値が 1 つずつずれた表が黙って返る。どの行で
/// 壊れていたかを添えて投げる (``malformed(path:line:reason:)``)。URL から読んだ本文も
/// 同じで、届いたが壊れている本文はファイルと同じ case で投げる。
///
/// `path` は口に渡した名前で、URL から読んだときはその URL である。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum DataFailure: Error, Equatable, Sendable {
    /// その名前のファイルが見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
    /// 見つかったが、UTF-8 の文字として読めない。
    case unreadable(path: String)
    /// 文字としては読めたが、形が壊れている。`line` は壊れていた行で、1 から数える。
    case malformed(path: String, line: Int, reason: String)
    /// 書き出せなかった。`reason` は書けなかった事情 (置き場が無い・書く権利が無いなど)。
    case unwritable(path: String, reason: String)
    /// URL から本文を受け取れなかった。`reason` は受け取れなかった事情 (繋がらない・
    /// 時間切れ・サーバが 2xx 以外の状態で答えた、など)。
    case unreachable(url: String, reason: String)
}

extension DataFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            AssetFailure.notFound(path: path, searched: searched).description
        case .unreadable(let path):
            "\"\(path)\" cannot be read as UTF-8 text. Check that the file is saved as UTF-8"
        case .malformed(let path, let line, let reason):
            "\"\(path)\" is broken at line \(line): \(reason)"
        case .unwritable(let path, let reason):
            "Cannot write \"\(path)\": \(reason)"
        case .unreachable(let url, let reason):
            "Cannot read \"\(url)\": \(reason)"
        }
    }
}
