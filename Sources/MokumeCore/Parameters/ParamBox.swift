// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
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
/// ## 非有限の数は載せない ([#2271])
///
/// **値を置く関所はここの 1 点である。** NaN も無限も受け取らず、**前の値を保って、1 度だけ
/// 名乗る** ([ADR-0030] 決定 3)。作者のコードからの代入 (``value`` の setter と `_modify`)・
/// 外からの書き込み・保存からの復元の 3 つの入口が、すべてここを通る。載せたままにすると、
/// 保存 (`params.json`) もつまみの応答も `JSONEncoder` が非有限を拒み、**他の値も含めて全部が
/// 書けなくなる**。出口ごとに落とし方を書く形は採らない — 出口を足すたびに書き直すことになる。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [#1782]: https://github.com/mokume-metal/mokume/issues/1782
/// [#2271]: https://github.com/mokume-metal/mokume/issues/2271
public final class ParamBox<Value: ParamRepresentable> {
    /// いまの値。
    ///
    /// **非有限の数 (NaN・無限、組と色は成分のどれか) を書いても、前の値のまま**で、そのことを
    /// 1 度だけ標準エラーへ名乗る。有限の値は範囲の外でも素通しする ([ADR-0030] 決定 3)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    public var value: Value {
        get {
            observation.access(self, keyPath: valueKeyPath)
            return storedValue
        }
        set {
            // 置かないときは変化の通知も出さない (値は動いていない)
            guard newValue.paramValue.hasOnlyFiniteNumbers else {
                refuse(newValue, keeping: storedValue)
                return
            }
            observation.withMutation(of: self, keyPath: valueKeyPath) {
                storedValue = newValue
            }
        }
        _modify {
            observation.access(self, keyPath: valueKeyPath)
            observation.willSet(self, keyPath: valueKeyPath)
            // 直に変えられた後でしか検められないので、前の値を控えて戻せるようにする
            let previous = storedValue
            defer {
                if !storedValue.paramValue.hasOnlyFiniteNumbers {
                    refuse(storedValue, keeping: previous)
                    storedValue = previous
                }
                observation.didSet(self, keyPath: valueKeyPath)
            }
            yield &storedValue
        }
    }

    private var storedValue: Value
    private let observation = ObservationRegistrar()

    /// この置き場が 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// 非有限の数を渡されて、受け取らなかった。
        case notFinite
    }

    /// 言った注意の控え。**検査が読む** (標準エラーへ実際に出た行は検査から読めない)。
    private(set) var warnings = WarningLog<Warning>()

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

    /// 非有限の数を受け取らなかったことを、**この置き場で 1 度だけ**名乗る。
    ///
    /// 毎フレーム書かれうる (`radius = .nan` を `draw()` に書いた作品) ので、繰り返さない。
    /// 名前と、渡された値と、保っている値を言う — 「どの値に何を書いて、いまいくつなのか」が
    /// 1 行で追える。
    private func refuse(_ offered: Value, keeping kept: Value) {
        warnings.warnOnce(
            .notFinite,
            "The knob \"\(name)\" was given \(offered), which is not a finite number, so it stays at "
                + "\(kept) (said once for this knob)")
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
    /// **非有限の数は収めずに拒む** (``ParamOutcome/notFinite``)。NaN は範囲に収まらず、
    /// 無限を端へ収めると `clamped` が「範囲へ収めた」という意味から外れる。宣言の型へ読み
    /// 替えて初めて無限になる数 (`1e300` を `Float` の値へ) も同じで、**読み替えた後で
    /// 検める**。拒んだ値は置かず、前の値のまま。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    func write(_ incoming: ParamValue) -> ParamOutcome {
        if case .string(let text) = incoming, let choices, !choices.contains(text) {
            return .notInChoices
        }
        let (settled, clamp) = clamped(incoming)
        guard let typed = Value(paramValue: settled) else { return .typeMismatch }
        // 入ってきた値と、読み替えた値の両方を見る。範囲へ収めると無限が端に化けるので、
        // 収める前の値を見ないと「無限を書かれた」ことが応答から消える
        guard incoming.hasOnlyFiniteNumbers, typed.paramValue.hasOnlyFiniteNumbers else {
            return .notFinite
        }
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
