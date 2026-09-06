// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import SwiftUI

/// つまみと正典 (``ParamBox``) を結ぶ。
///
/// **写しを作らない。** `get` はそのつど正典を読み、`set` は正典へ書く。窓の側に値を
/// 置くと、外から書き換えられた値が窓に映らなくなるか、窓の値が毎フレーム書き戻される
/// かのどちらかになる。
///
/// 書き込みは面と同じ入口 (``DeclaredParam/write(_:)``) を通す — 収める規則を窓と面で
/// 2 通り持たない ([ADR-0030] 決定 3)。
///
/// **窓を通した往復の検査もここを通る** ([#517](https://github.com/mokume-metal/mokume/issues/517)
/// 出口条件 1)。``DeclaredParam/write(_:)`` を検査から直接呼ぶと「窓を通した」ことに
/// ならず、ここが写しを持ち始めても緑のままになるので、**窓のファイルの外に置く**
/// (同じ理由で ``KnobColor`` と ``KnobText`` も別のファイルにある)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum KnobBinding {
    /// 数。整数の宣言には整数として書き戻す。
    static func number(_ box: any DeclaredParam, _ current: ParamValue) -> Binding<Double> {
        let isInteger = current.isInteger
        return Binding(
            get: { box.declaration.value.asDouble ?? 0 },
            set: { _ = box.write(isInteger ? .int(Int($0.rounded())) : .float($0)) })
    }

    static func flag(_ box: any DeclaredParam) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let value) = box.declaration.value { value } else { false } },
            set: { _ = box.write(.bool($0)) })
    }

    static func text(_ box: any DeclaredParam) -> Binding<String> {
        Binding(
            get: { if case .string(let value) = box.declaration.value { value } else { "" } },
            set: { _ = box.write(.string($0)) })
    }

    /// 組の 1 成分。**他の成分は読み直した値をそのまま置く** — 窓が組を丸ごと持つと、
    /// 外から 1 成分だけ書き換えられたときに古い成分で上書きしてしまう。
    static func component(_ box: any DeclaredParam, at index: Int) -> Binding<Double> {
        Binding(
            get: { Double(box.declaration.value.component(at: index) ?? 0) },
            set: { moved in
                guard var components = box.declaration.value.components, index < components.count
                else { return }
                components[index] = Float(moved)
                guard let value = ParamValue(components: components) else { return }
                _ = box.write(value)
            })
    }

    /// 色。**作業空間の値と画面の色の変換は境界の 1 箇所** ([ADR-0011] 決定 3・4) を通す。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static func color(_ box: any DeclaredParam) -> Binding<Color> {
        Binding(
            get: {
                guard case .color(let value) = box.declaration.value else { return .clear }
                return KnobColor.display(of: value)
            },
            set: { _ = box.write(.color(KnobColor.working(of: $0))) })
    }
}

// MARK: - 値の読み方

extension ParamValue {
    /// 整数として宣言された値か。
    fileprivate var isInteger: Bool {
        if case .int = self { return true }
        return false
    }

    /// 数として読む。数でなければ `nil`。
    fileprivate var asDouble: Double? {
        switch self {
        case .float(let value): value
        case .int(let value): Double(value)
        case .bool, .string, .color, .vector2, .vector3: nil
        }
    }

    /// 組の成分として読む。組でなければ `nil`。
    fileprivate var components: [Float]? {
        switch self {
        case .vector2(let value): [value.x, value.y]
        case .vector3(let value): [value.x, value.y, value.z]
        case .float, .int, .bool, .string, .color: nil
        }
    }

    /// 組の 1 成分として読む。組でないか、その番号が無ければ `nil`。
    ///
    /// **番号が範囲の外なら `nil` を返す。** 成分の数は型で決まる (組 2 なら 2 つ)
    /// が、番号を渡す側は窓の行なので、宣言が差し替わった瞬間に古い番号で読みうる。
    fileprivate func component(at index: Int) -> Float? {
        guard let components, components.indices.contains(index) else { return nil }
        return components[index]
    }

    /// 成分から組を組み立てる。成分の数が 2 でも 3 でもなければ `nil`。
    fileprivate init?(components: [Float]) {
        switch components.count {
        case 2: self = .vector2(SIMD2(components[0], components[1]))
        case 3: self = .vector3(SIMD3(components[0], components[1], components[2]))
        default: return nil
        }
    }
}
