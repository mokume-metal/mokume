// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 資材の名前から、在るファイルを探せなかったこと。``Sketch/assetURL(_:)`` が投げる。
public enum AssetFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
}

extension AssetFailure: CustomStringConvertible {
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
        }
    }
}
