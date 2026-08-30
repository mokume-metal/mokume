// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Observation

/// 宣言した値の置き場。``Param(name:)`` の展開が作るもので、手で書くことはない。
///
/// **値の実体はここ 1 つだけである** ([ADR-0013] 決定 3)。窓のつまみも、外からの
/// 書き込みも、保存からの復元も、この 1 つを読み書きする入口であって値の複製を
/// 持たない。変更の追跡は Observation に載せる (同 決定 1) ので、窓の更新のために
/// 登録も通知も書かない。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
@Observable
public final class ParamBox<Value: ParamRepresentable> {
    /// いまの値。
    public var value: Value

    /// 面から指すときの名前。
    @ObservationIgnored public let name: String
    /// つまみが動ける幅。
    @ObservationIgnored public let range: ParamRange?
    /// 許した候補。
    @ObservationIgnored public let choices: [String]?

    public init(name: String, value: Value, range: ParamRange? = nil, choices: [String]? = nil) {
        self.name = name
        self.value = value
        self.range = range
        self.choices = choices
    }
}

extension ParamBox: DeclaredParam {
    /// 面から見えるいまの姿。
    public var declaration: ParamDeclaration {
        ParamDeclaration(name: name, value: value.paramValue, range: range, choices: choices)
    }

    /// 面から来た値を書き込む。
    ///
    /// **範囲は面のための宣言であって、値の不変条件ではない** ([ADR-0030] 決定 3)。
    /// だから範囲へ収めるのはここ (外から来た書き込み) だけで、作者のコードからの
    /// 代入は ``value`` へ直接入り、素通しになる。
    ///
    /// 範囲の外は拒否ではなく**収めたうえで、収めたことを応答に載せる** — 拒否に
    /// すると値を掃引する書き手が端で毎回弾かれ、黙って収めると書いた値と読める値が
    /// 食い違う理由が分からない。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    func write(_ incoming: ParamValue) -> ParamOutcome {
        if case .string(let text) = incoming, let choices, !choices.contains(text) {
            return .notInChoices
        }
        let (settled, clamp) = clamped(incoming)
        guard let typed = Value(paramValue: settled) else { return .typeMismatch }
        value = typed
        return clamp
    }

    /// 範囲へ収める。数でない値と、範囲を書いていない値はそのまま。
    private func clamped(_ incoming: ParamValue) -> (ParamValue, ParamOutcome) {
        guard let range else { return (incoming, .applied) }
        switch incoming {
        case .float(let number):
            let settled = range.clamped(number)
            guard settled != number else { return (incoming, .applied) }
            return (.float(settled), .clamped(requested: number, applied: settled))
        case .int(let number):
            let settled = Int(range.clamped(Double(number)).rounded())
            guard settled != number else { return (incoming, .applied) }
            return (.int(settled), .clamped(requested: Double(number), applied: Double(settled)))
        case .bool, .string, .color, .vector2, .vector3:
            return (incoming, .applied)
        }
    }
}

/// 型を伏せた ``ParamBox``。宣言の一覧を集めるときと、面から書き込むときに使う。
protocol DeclaredParam: AnyObject {
    var declaration: ParamDeclaration { get }
    func write(_ incoming: ParamValue) -> ParamOutcome
}
