// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 断片を読み込めなかった理由。
public enum ShaderFailure: Error, Equatable, Sendable {
    /// 断片が見つからない。探した場所を添える。
    case notFound(path: String, searched: [String])
    /// 断片を組み立てられない。理由はコンパイラの言葉のまま。
    case notCompilable(path: String, reason: String)
    /// 渡す値が列 1 つぶんの区画に収まらない。float 換算の数と上限を添える。
    case tooManyValues(path: String, count: Int, capacity: Int)
    /// 渡す面が口の数に収まらない。枚数と上限を添える。
    case tooManySurfaces(path: String, count: Int, capacity: Int)
}

extension ShaderFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            return """
                Cannot find the fragment "\(path)".
                Looked in:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                If you did put it there, check that the package declares where its resources are \
                (`.executableTarget(..., resources: [.copy("assets")])`). \
                Without that declaration the build still passes quietly, and the file just cannot \
                be read at run time
                """
        case .notCompilable(let path, let reason):
            return "Cannot build the fragment at \"\(path)\":\n\(reason)"
        case .tooManyValues(let path, let count, let capacity):
            return """
                Too many values for the fragment "\(path)" (\(count) counted as floats, but the \
                limit is \(capacity)).
                A color (float4) counts as 4 and a pair (float2) as 2 \
                (a struct's size rounds up to a multiple of 4, so the count can come out higher \
                than what you declared).
                The values ride in one fixed-size block per batch (per request, for compute), so \
                the limit cannot be raised. Pass fewer, or bundle what you can into a single color \
                or pair
                """
        case .tooManySurfaces(let path, let count, let capacity):
            return """
                Too many surfaces for the fragment "\(path)" (\(count), but the limit is \
                \(capacity)).
                Each named surface takes one slot, and the number of slots is fixed whatever the \
                fragment. Pass fewer, or combine several pictures into one (bake them side by \
                side, and pick one by where you read)
                """
        }
    }
}
