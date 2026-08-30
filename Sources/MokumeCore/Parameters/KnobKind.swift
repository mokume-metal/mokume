// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 宣言 1 つに対して窓が出すつまみ。
///
/// **型からつまみへの対応は 1 通りに固定する** ([ADR-0030] 決定 8)。決めるのはここ
/// 1 箇所で、SwiftUI の側は決まったものを組むだけである — 対応の規則は AppKit を
/// 立ち上げずに検められる必要があり、窓の中に埋めるとそれができない。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum KnobKind: Equatable {
    /// 実数のスライダー。
    case slider(ParamRange)
    /// 整数のスライダー。刻みは 1。
    case steppedSlider(ParamRange)
    /// 真偽のトグル。
    case toggle
    /// 色の選択。
    case color
    /// 成分ごとのスライダー。組の成分の数だけ並ぶ。
    case components(count: Int, range: ParamRange)
    /// 候補から選ぶ。
    case choice([String])
    /// つまみを出さない。値だけを、触れない見た目で出す。
    case none(Reason)

    /// つまみを出さない理由。**黙って消さない** — 窓に並ばない値があると、書いたのに
    /// 効かないのか出していないだけなのかが読み手には区別できない。
    enum Reason: Equatable {
        /// 数値だが範囲を書いていない。
        case rangeNotDeclared
        /// 文字だが候補を書いていない。
        case choicesNotDeclared

        /// 窓に添える 1 行。**次に何を書けばよいかまで書く。**
        var note: String {
            switch self {
            case .rangeNotDeclared: "範囲を書くとつまみが出ます"
            case .choicesNotDeclared: "候補を書くとつまみが出ます"
            }
        }
    }
}

extension KnobKind {
    /// 宣言からつまみを決める。
    ///
    /// **範囲を書かなかった数値には、つまみを出さない** ([ADR-0030] 決定 8)。値から
    /// 範囲を推す形は採らない — 推した範囲を毎フレーム測り直すと引いている最中に範囲
    /// そのものが動いてつまみが逃げ、1 度だけ決めて固定すると「なぜこの端なのか」を
    /// 説明できない。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    static func forDeclaration(_ declaration: ParamDeclaration) -> KnobKind {
        switch declaration.value {
        case .float:
            guard let range = declaration.range else { return .none(.rangeNotDeclared) }
            return .slider(range)
        case .int:
            guard let range = declaration.range else { return .none(.rangeNotDeclared) }
            return .steppedSlider(range)
        case .bool:
            return .toggle
        case .color:
            return .color
        case .vector2:
            guard let range = declaration.range else { return .none(.rangeNotDeclared) }
            return .components(count: 2, range: range)
        case .vector3:
            guard let range = declaration.range else { return .none(.rangeNotDeclared) }
            return .components(count: 3, range: range)
        case .string:
            // 候補を書いていない文字は、窓からは触らせない。自由に打てる欄を出すと
            // 「作者が想定していない文字が入った状態」を窓が作れてしまい、その状態を
            // 面の側 (候補による拒否) と揃える方法が無くなる
            guard let choices = declaration.choices, !choices.isEmpty else {
                return .none(.choicesNotDeclared)
            }
            return .choice(choices)
        }
    }
}
