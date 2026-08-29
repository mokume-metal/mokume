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
        case .tooManyValues(let path, let count, let capacity):
            return """
                断片「\(path)」へ渡す値が多すぎます (float 換算 \(count) 個 / 上限 \(capacity) 個)。
                色 (float4) は 4 個ぶん・2 つ組 (float2) は 2 個ぶんに数えます \
                (構造体の大きさは 4 個の倍数へ切り上がるので、数え上げが宣言より増えることがあります)。
                値は列ごとに 1 区画へ載せるので上限は動かせません。数を減らすか、\
                まとめられるものを 1 つの色・2 つ組へ束ねてください。
                """
        }
    }
}
