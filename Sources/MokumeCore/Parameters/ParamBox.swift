// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Observation

/// 宣言した値の置き場。``Param(_:name:)`` の展開が作るもので、手で書くことはない。
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
}

/// 型を伏せた ``ParamBox``。宣言の一覧を集めるときだけ使う。
protocol DeclaredParam: AnyObject {
    var declaration: ParamDeclaration { get }
}
