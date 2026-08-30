// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// つまみが動ける幅。
///
/// **範囲は面のための宣言であって、値の不変条件ではない** ([ADR-0030] 決定 3)。
/// 外から来た書き込みはここへ収めるが、作者が書いたコードからの代入は素通しする。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
public struct ParamRange: Equatable, Sendable {
    /// 下端。
    public let lowerBound: Double
    /// 上端。
    public let upperBound: Double

    public init(_ range: ClosedRange<Double>) {
        lowerBound = range.lowerBound
        upperBound = range.upperBound
    }

    public init(_ range: ClosedRange<Int>) {
        lowerBound = Double(range.lowerBound)
        upperBound = Double(range.upperBound)
    }

    /// 範囲へ収めた値を返す。
    public func clamped(_ value: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}

/// 宣言された 1 つの値の、面から見える姿。
///
/// 名前・型・範囲・候補が揃っているので、読み手は値を試し打ちせずに何を書けるか
/// 決められる。名前は**コンパイル時に確定**しており、コードに書いた名前と一致する
/// ([ADR-0030] 決定 5)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
public struct ParamDeclaration: Equatable, Sendable {
    /// 面から指すときの名前。
    public let name: String
    /// いまの値。
    public let value: ParamValue
    /// つまみが動ける幅。書かれていなければ `nil`。
    public let range: ParamRange?
    /// 許した候補。文字の値にだけ付く。
    public let choices: [String]?

    public init(name: String, value: ParamValue, range: ParamRange? = nil, choices: [String]? = nil) {
        self.name = name
        self.value = value
        self.range = range
        self.choices = choices
    }

    /// 形式の中で名乗る型の名前。
    public var typeName: String { value.typeName }
}
