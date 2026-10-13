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
    /// 整数で書かれた範囲の、整数のままの端。**整数の値はこちらで収める。**
    ///
    /// `Double` の端は 2^53 を超える整数を正確に持てない (`Double(Int.max)` は 2^63 に丸まる)。
    /// 整数の値を `Double` へ移して収め直すと、宣言した端の外の値が範囲の中として通り、
    /// 範囲の中の値が丸められる ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。
    /// 整数の宣言は端も整数のまま持ち、整数の値は `Int` のまま収める。`Double` で書かれた
    /// 範囲 (`nil`) は従来どおり `Double` で収める。
    let integerBounds: ClosedRange<Int>?

    public init(_ range: ClosedRange<Double>) {
        lowerBound = range.lowerBound
        upperBound = range.upperBound
        integerBounds = nil
    }

    public init(_ range: ClosedRange<Int>) {
        lowerBound = Double(range.lowerBound)
        upperBound = Double(range.upperBound)
        integerBounds = range
    }

    /// 端は `Double` の値で比べる。**整数で書いたか実数で書いたかでは区別しない**
    /// (`ParamRange(0...10)` と、応答から読み直した同じ端の範囲は等しい)。
    public static func == (lhs: ParamRange, rhs: ParamRange) -> Bool {
        lhs.lowerBound == rhs.lowerBound && lhs.upperBound == rhs.upperBound
    }

    /// 範囲へ収めた値を返す。
    public func clamped(_ value: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }

    /// 組の成分 1 つを、この範囲の中へ収める。
    func clamped(_ component: Float) -> Float {
        Float(clamped(Double(component)))
    }

    /// 整数の値を、この範囲へ収める。**整数で書かれた範囲は `Int` のまま収める**ので、
    /// 2^53 を超える整数も丸めず、宣言した端そのものを書けば収めたことにならない。
    func clamped(_ value: Int) -> Int {
        guard let integerBounds else {
            return Int(roundingAndSaturating: clamped(Double(value)))
        }
        return min(max(value, integerBounds.lowerBound), integerBounds.upperBound)
    }
}

extension Int {
    /// 最も近い整数。**`Int` に収まらなければ、近いほうの端へ収める。**
    ///
    /// `Int(_: Double)` は収まらない値で**プロセスごと落ちる**。窓のスライダーが返す実数
    /// (範囲の右端は `Double(Int.max)` = 2^63) を整数へ戻す所は、この変換を通す
    /// ([#2478](https://github.com/mokume-metal/mokume/issues/2478))。
    ///
    /// NaN は 0 を返す (落とさないための値で、意味は無い)。**この手前で NaN は拒まれない**
    /// — 整数の値は `hasOnlyFiniteNumbers` が常に有限と読むので、窓の整数のつまみが NaN を
    /// 出せば 0 になる。窓のスライダーは有限の値しか出さないので、実際には通らない。
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
