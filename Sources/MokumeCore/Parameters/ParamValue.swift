// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走らせたまま動かせる値の、面に出る表現。
///
/// **型を値の隣に書く。** 値だけを裸で置くと、読み手は 1.0 が実数なのか整数なのかを
/// 推測することになる。名乗り方は観測が差し出す値と同じ形で、同じ意味の表現を
/// 2 つ持たない ([ADR-0030] 決定 4)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
public enum ParamValue: Equatable, Sendable {
    case float(Double)
    case int(Int)
    case bool(Bool)
    case string(String)
    case color(LinearRGBA)
    case vector2(SIMD2<Float>)
    case vector3(SIMD3<Float>)

    /// 形式の中で名乗る型の名前。
    public var typeName: String { paramType.rawValue }

    /// 名乗る型。**綴りの正典は ``ParamTypeName``** で、読む側も同じものを引く —
    /// 書いたものを自分で読めない状態が、この網羅 `switch` から先へ進めない。
    var paramType: ParamTypeName {
        switch self {
        case .float: .float
        case .int: .int
        case .bool: .bool
        case .string: .string
        case .color: .color
        case .vector2: .vec2
        case .vector3: .vec3
        }
    }

    /// 数として読めるか (つまみの範囲が意味を持つのはこの 2 つだけ)。
    public var isNumber: Bool {
        switch self {
        case .float, .int: true
        case .bool, .string, .color, .vector2, .vector3: false
        }
    }
}

/// 面に出せる値。
///
/// 面に出る型は最小に保つ ([ADR-0024] 決定 8)。単位を持つ値 (角度・時間・長さ) を
/// 型で分けないのは同じ規律で、単位は名前と説明が持つ。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol ParamRepresentable: Sendable {
    /// 面に出る表現。
    var paramValue: ParamValue { get }
    /// 面から来た表現を、この型として読む。型が違えば `nil`。
    init?(paramValue: ParamValue)
}

extension Double: ParamRepresentable {
    public var paramValue: ParamValue { .float(self) }
    public init?(paramValue: ParamValue) {
        guard case .float(let value) = paramValue else { return nil }
        self = value
    }
}

extension Float: ParamRepresentable {
    /// `Float` と `Double` はどちらも `float` を名乗る。面に出る形は数値なので、
    /// 精度の違いを型の名前で分けても読み手にできることが増えない。
    public var paramValue: ParamValue { .float(Double(self)) }
    public init?(paramValue: ParamValue) {
        guard case .float(let value) = paramValue else { return nil }
        self = Float(value)
    }
}

extension Int: ParamRepresentable {
    public var paramValue: ParamValue { .int(self) }
    public init?(paramValue: ParamValue) {
        guard case .int(let value) = paramValue else { return nil }
        self = value
    }
}

extension Bool: ParamRepresentable {
    public var paramValue: ParamValue { .bool(self) }
    public init?(paramValue: ParamValue) {
        guard case .bool(let value) = paramValue else { return nil }
        self = value
    }
}

extension String: ParamRepresentable {
    public var paramValue: ParamValue { .string(self) }
    public init?(paramValue: ParamValue) {
        guard case .string(let value) = paramValue else { return nil }
        self = value
    }
}

extension LinearRGBA: ParamRepresentable {
    /// 色は作業空間の表現そのものを出す。公開の面に出る色の型がそれである以上
    /// ([ADR-0020] 決定 6)、往復に変換を挟まない ([ADR-0030] 決定 4)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    public var paramValue: ParamValue { .color(self) }
    public init?(paramValue: ParamValue) {
        guard case .color(let value) = paramValue else { return nil }
        self = value
    }
}

extension SIMD2<Float>: ParamRepresentable {
    public var paramValue: ParamValue { .vector2(self) }
    public init?(paramValue: ParamValue) {
        guard case .vector2(let value) = paramValue else { return nil }
        self = value
    }
}

extension SIMD3<Float>: ParamRepresentable {
    public var paramValue: ParamValue { .vector3(self) }
    public init?(paramValue: ParamValue) {
        guard case .vector3(let value) = paramValue else { return nil }
        self = value
    }
}
