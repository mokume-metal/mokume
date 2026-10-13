// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// つまみが動ける幅。
///
/// **範囲は面のための宣言であって、値の不変条件ではない** ([ADR-0030] 決定 3)。
/// 外から来た書き込みはここへ収めるが、作者が書いたコードからの代入は素通しする
/// (非有限の数だけは、どちらの入口でも受け取らない)。
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

    /// 組の成分 1 つを、この範囲の中へ収める。
    func clamped(_ component: Float) -> Float {
        Float(clamped(Double(component)))
    }
}

extension Int {
    /// 最も近い整数。**`Int` に収まらなければ、近いほうの端へ収める。**
    ///
    /// `Int(_: Double)` は収まらない値で**プロセスごと落ちる**。範囲を `Double` で持つので、
    /// 上端が `Int.max` の宣言は収めた後の値が `Int` に収まらない 2^63 になりうる
    /// (`Double(Int.max)` は丸めで 2^63 になる)。外から来る値も窓のスライダーも同じ変換を
    /// 通るので、変換はここ 1 か所にする ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。
    ///
    /// NaN は受け取らない前提で、端のどちらでもなく 0 を返す (落とさないための値で、意味は無い)。
    /// 非有限の数は ``ParamBox`` がこれより手前で拒む。
    init(roundingAndSaturating value: Double) {
        let rounded = value.rounded()
        if let exact = Int(exactly: rounded) {
            self = exact
        } else if rounded.isNaN {
            self = 0
        } else {
            self = rounded < 0 ? .min : .max
        }
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
