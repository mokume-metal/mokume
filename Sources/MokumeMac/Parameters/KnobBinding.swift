// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import SwiftUI

/// つまみと正典 (``ParamBox``) を結ぶ。
///
/// **写しを作らない。** `get` はそのつど正典を読み、`set` は正典へ書く。ウィンドウの側に値を
/// 置くと、外から書き換えられた値がウィンドウに映らなくなるか、ウィンドウの値が毎フレーム書き戻される
/// かのどちらかになる。
///
/// 書き込みは面と同じ入口 (``DeclaredParam/write(_:)``) を通す — 収める規則をウィンドウと面で
/// 2 通り持たない ([ADR-0030] 決定 3)。
///
/// **ウィンドウを通した往復の検査もここを通る** ([#517](https://github.com/mokume-metal/mokume/issues/517)
/// 出口条件 1)。``DeclaredParam/write(_:)`` を検査から直接呼ぶと「ウィンドウを通した」ことに
/// ならず、ここが写しを持ち始めても緑のままになるので、**ウィンドウのファイルの外に置く**
/// (同じ理由で ``KnobColor`` と ``KnobText`` も別のファイルにある)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum KnobBinding {
    /// 数。整数の宣言には整数として書き戻す。
    ///
    /// `history` を渡せば、掴んでいない間の書き込み (クリックで飛ばす・キー操作) を 1 段として積む。
    /// 掴んでいる間は積まず、離したときに ``editing(_:history:)`` が 1 段にする (#4124)。
    static func number(
        _ box: any DeclaredParam, _ current: ParamValue, history: KnobHistory? = nil
    ) -> Binding<Double> {
        let isInteger = current.isInteger
        return Binding(
            get: { box.declaration.value.asDouble ?? 0 },
            set: {
                write(box, isInteger ? .int(Int(roundingAndSaturating: $0)) : .float($0), history)
            })
    }

    static func flag(_ box: any DeclaredParam, history: KnobHistory? = nil) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let value) = box.declaration.value { value } else { false } },
            set: { write(box, .bool($0), history) })
    }

    static func text(_ box: any DeclaredParam, history: KnobHistory? = nil) -> Binding<String> {
        Binding(
            get: { if case .string(let value) = box.declaration.value { value } else { "" } },
            set: { write(box, .string($0), history) })
    }

    /// 組の 1 成分。**他の成分は読み直した値をそのまま置く** — ウィンドウが組を丸ごと持つと、
    /// 外から 1 成分だけ書き換えられたときに古い成分で上書きしてしまう。
    static func component(
        _ box: any DeclaredParam, at index: Int, history: KnobHistory? = nil
    ) -> Binding<Double> {
        Binding(
            get: { Double(box.declaration.value.component(at: index) ?? 0) },
            set: { moved in
                guard var components = box.declaration.value.components, index < components.count
                else { return }
                components[index] = Float(moved)
                guard let value = ParamValue(components: components) else { return }
                write(box, value, history)
            })
    }

    /// 色。**作業空間の値と画面の色の変換は境界の 1 箇所** ([ADR-0011] 決定 3・4) を通す。
    ///
    /// 色のパネルは値を流し続けるだけで操作の終わりを知らせないので、書き込みが途切れるまでを 1 段にする
    /// (``KnobHistory/recordContinuous(name:before:after:)``)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static func color(_ box: any DeclaredParam, history: KnobHistory? = nil) -> Binding<Color> {
        Binding(
            get: {
                guard case .color(let value) = box.declaration.value else { return .clear }
                return KnobColor.display(of: value)
            },
            set: { write(box, .color(KnobColor.working(of: $0)), history, continuous: true) })
    }

    /// スライダーを掴んだ・離した (`Slider` の `onEditingChanged`)。掴んでから離すまでを 1 段として積む。
    static func editing(_ box: any DeclaredParam, history: KnobHistory?) -> (Bool) -> Void {
        { began in
            guard let history else { return }
            let declaration = box.declaration
            if began {
                history.beginGesture(name: declaration.name, value: declaration.value)
            } else {
                history.endGesture(name: declaration.name, value: declaration.value)
            }
        }
    }

    /// 書いて、書く前と後の値を履歴に積む。**後の値は書いた後に読み直す** — 収めた値 (範囲の端) を
    /// 積まないと、やり直したときに収める前の値を書くことになる。
    private static func write(
        _ box: any DeclaredParam, _ value: ParamValue, _ history: KnobHistory?,
        continuous: Bool = false
    ) {
        let before = box.declaration.value
        _ = box.write(value)
        guard let history else { return }
        let after = box.declaration
        if continuous {
            history.recordContinuous(name: after.name, before: before, after: after.value)
        } else {
            history.record(name: after.name, before: before, after: after.value)
        }
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
    /// が、番号を渡す側はウィンドウの行なので、宣言が差し替わった瞬間に古い番号で読みうる。
    fileprivate func component(at index: Int) -> Float? {
        guard let components, components.indices.contains(index) else { return nil }
        return components[index]
    }

    /// 成分から組を組み立てる。成分の数が 2 でも 3 でもなければ `nil`。
    fileprivate init?(components: [Float]) {
        switch components.count {
        case 2: self = .vector2(Vector2(components[0], components[1]))
        case 3: self = .vector3(Vector3(components[0], components[1], components[2]))
        default: return nil
        }
    }
}
