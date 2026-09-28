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
/// ## `@Observable` を手で展開している ([#1782])
///
/// 中身は Swift 6.3 の `@Observable` の展開そのままで、**違いは key path を作る場所
/// だけ**である。macro の展開は読むたびに `\.value` を書くが、この型は総称なので、
/// その key path は呼ぶたびに実行時に組み立てられて捨てられる (`swift_getKeyPath`)。
/// スケッチが `@Param` の値を 1 回読むのに約 490 ns かかっていた (素の読みは 1 ns
/// 未満)。作るのを初期化の 1 度にし、以後は同じものを渡す。
///
/// key path は構造で等しさを判定するので、観測の登録と通知は macro の展開と一致する。
/// setter は `Value` が `Equatable` を要求しないので、展開と同じく常に通知する
/// (`shouldNotifyObservers` が常に真になる形)。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [#1782]: https://github.com/mokume-metal/mokume/issues/1782
public final class ParamBox<Value: ParamRepresentable> {
    /// いまの値。
    public var value: Value {
        get {
            observation.access(self, keyPath: valueKeyPath)
            return storedValue
        }
        set {
            observation.withMutation(of: self, keyPath: valueKeyPath) {
                storedValue = newValue
            }
        }
        _modify {
            observation.access(self, keyPath: valueKeyPath)
            observation.willSet(self, keyPath: valueKeyPath)
            defer { observation.didSet(self, keyPath: valueKeyPath) }
            yield &storedValue
        }
    }

    private var storedValue: Value
    private let observation = ObservationRegistrar()
    /// ``value`` を指す key path。**初期化で 1 度だけ作る** (型の説明を参照)。
    private let valueKeyPath: KeyPath<ParamBox, Value>

    /// 面から指すときの名前。
    public let name: String
    /// つまみが動ける幅。
    public let range: ParamRange?
    /// 許した候補。
    public let choices: [String]?

    public init(name: String, value: Value, range: ParamRange? = nil, choices: [String]? = nil) {
        self.name = name
        self.storedValue = value
        self.valueKeyPath = \ParamBox<Value>.value
        self.range = range
        self.choices = choices
    }
}

extension ParamBox: nonisolated Observable {}

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

    /// 範囲へ収める。範囲が意味を持たない型 (真偽・文字・色) と、範囲を書いていない値はそのまま。
    ///
    /// **組は成分ごとに、宣言した 1 つの範囲へ独立に収める。** 窓の成分スライダーが
    /// 同じ 1 つの範囲で縛っているので、外から書ける幅をそれと揃える
    /// ([#859](https://github.com/mokume-metal/mokume/issues/859))。
    private func clamped(_ incoming: ParamValue) -> (ParamValue, ParamOutcome) {
        guard let range else { return (incoming, .applied) }
        let settled: ParamValue
        switch incoming {
        case .float(let number):
            settled = .float(range.clamped(number))
        case .int(let number):
            settled = .int(Int(range.clamped(Double(number)).rounded()))
        case .vector2(let vector):
            settled = .vector2(SIMD2(range.clamped(vector.x), range.clamped(vector.y)))
        case .vector3(let vector):
            settled = .vector3(
                SIMD3(range.clamped(vector.x), range.clamped(vector.y), range.clamped(vector.z)))
        case .bool, .string, .color:
            return (incoming, .applied)
        }
        guard settled != incoming else { return (incoming, .applied) }
        return (settled, .clamped(requested: incoming, applied: settled))
    }
}

/// 型を伏せた ``ParamBox``。宣言の一覧を集めるときと、面から書き込むときに使う。
protocol DeclaredParam: AnyObject {
    var declaration: ParamDeclaration { get }
    func write(_ incoming: ParamValue) -> ParamOutcome
}
