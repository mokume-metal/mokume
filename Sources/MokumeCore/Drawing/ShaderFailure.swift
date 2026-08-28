// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 断片を読み込めなかった理由。
public enum ShaderFailure: Error, Equatable, Sendable {
    /// 断片が見つからない。探した場所を添える。
    case notFound(path: String, searched: [String])
    /// 断片を組み立てられない。理由はコンパイラの言葉のまま。
    case notCompilable(path: String, reason: String)
}

extension ShaderFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            return """
                断片「\(path)」が見つかりません。
                探した場所:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                置いたはずなら、パッケージの宣言に資材の置き場が書かれているか確かめてください \
                (`.executableTarget(..., resources: [.copy("assets")])`)。\
                宣言が無いとビルドは静かに通り、実行時に読めないだけになります。
                """
        case .notCompilable(let path, let reason):
            return "断片「\(path)」を組み立てられません:\n\(reason)"
        }
    }
}
