// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// JSON と XML の値を取り出す口 (``JSONObject`` / ``XML``) が 1 度だけ言う注意。
///
/// 値の型で持ち主が無いので、控えをここに置く。形は ``TableValues`` と同じで、鍵で数える
/// 仕組みは ``WarningLog`` が持つ。
///
/// **鍵はキーや属性の名前ごとに分ける** (表の列と同じ)。名前はスケッチの文字に書かれた
/// ものなので、鍵の数はフレームで増えない。
enum DocumentValues {
    /// 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// JSON のオブジェクトに、そのキーが無い。
        case noKey(String)
        /// JSON のキーの値が、数として読めない。
        case notANumber(key: String)
        /// JSON のキーの値が、オブジェクトでない。
        case notAnObject(key: String)
        /// JSON のキーの値が、文字でない。
        case notAString(key: String)
        /// JSON のキーの値が、整数の値として読めない (整数でない数・`Int` に収まらない数・数でない値)。
        case notAnInteger(key: String)
        /// JSON のキーの値が、真偽でない。
        case notABoolean(key: String)
        /// JSON のキーの値が、配列でない。
        case notAnArray(key: String)
        /// JSON の配列から、範囲の外の番号か種類の違う要素を取り出した。**番号ごとではなく、口の
        /// 名前と事情の組ごと**に 1 度だけ言う (番号で数えると、配列の大きさだけ控えが増える)。
        case arrayElement(call: String, problem: ArrayProblem)
        /// XML の要素に、その名前の属性が無い。
        case noAttribute(element: String, name: String)
        /// XML の属性の値が、数として読めない。
        case attributeNotANumber(element: String, name: String)
        /// XML の要素に子があるのに、その名前の子が 1 つも無い。
        case noChild(element: String, name: String)
    }

    /// 配列の要素の取り出しで起きる事情。
    enum ArrayProblem: Hashable {
        /// 番号が、配列の範囲の外。
        case outOfRange
        /// 要素の種類が、読もうとした種類と違う。
        case wrongKind
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    /// 在る名前の一覧を 1 文にする (`Its keys are: "main", "name"`)。
    ///
    /// **並べるのは 20 個まで。** 大きな応答のキーを全部並べると、知らせが読めなくなる。
    static func listing(_ lead: String, _ names: some Sequence<String>) -> String {
        let sorted = names.sorted()
        guard !sorted.isEmpty else { return "\(lead): (none)" }
        let shown = sorted.prefix(20).map { "\"\($0)\"" }.joined(separator: ", ")
        return sorted.count > 20 ? "\(lead): \(shown), … (\(sorted.count) in all)" : "\(lead): \(shown)"
    }
}
