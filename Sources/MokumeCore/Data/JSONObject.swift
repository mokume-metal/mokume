// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON のオブジェクト (`{ "キー": 値, … }`)。ファイルか URL から読んで作り
/// (``Sketch/loadJSONObject(_:)``)、キーで値を取り出す。
///
/// <!-- example: 文脈 var temp: Float? -->
/// ```swift
/// func setup() {
///     // 応答は { "name": "Sapporo", "main": { "temp": -3.5 } } の形
///     let weather = try? loadJSONObject("data/weather.json")
///     temp = weather?.getJSONObject("main").getFloat("temp")
/// }
/// ```
///
/// ## 型を書かずに読む
///
/// 読む前に応答の形を型として宣言しなくてよい。欲しい値を、キーを辿って取り出す
/// (``getJSONObject(_:)`` で入れ子へ降り、``getFloat(_:)`` で数を取る)。
///
/// ## 値の型である
///
/// 代入すると写しになる (``Table`` と同じ)。読むだけで、書き換える口は持たない。
///
/// ## 値が無くても落ちない
///
/// 無いキーや、思っていたのと違う種類の値を取り出しても、取り出す口は落ちない。``getFloat(_:)``
/// は NaN、``getJSONObject(_:)`` は空のオブジェクトを返し、**初回だけ理由を知らせる**
/// ([ADR-0020] 決定 5)。だから入れ子を繋いだまま書ける — 途中のキーが欠けていれば、最後の
/// 数が NaN になり、知らせが欠けたキーを名指す。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public struct JSONObject: Equatable, Sendable {
    /// キーと値。順は持たない (JSON のオブジェクトは順を約束しない)。
    let members: [String: JSONValue]

    init(_ members: [String: JSONValue]) {
        self.members = members
    }

    /// キーの値を数として読む。
    ///
    /// <!-- example: 文脈 var weather: JSONObject! -->
    /// ```swift
    /// let temp = weather.getJSONObject("main").getFloat("temp")
    /// circle(width / 2, height / 2, 100 + temp * 4)
    /// ```
    ///
    /// 数の値はそのまま、数の文字 (`"18.5"`。前後の空白は落とす) は数として読む。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — キーが無い・値が
    /// `true` / `false` / `null`・オブジェクト・配列・数でない文字のどれでも (キーごとに 1 度)。
    /// 読み取りは落ちない ([ADR-0020] 決定 5)。NaN は表の ``TableRow/getFloat(_:)-(String)`` が
    /// 欠けた値に返すものと同じで、0 のように黙って別の値に化けない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getFloat(_ key: String) -> Float {
        guard let value = member(key, call: "getFloat") else { return .nan }
        switch value {
        case .number(let number):
            return Float(number)
        case .string(let text):
            if let number = Float(text.trimmingCharacters(in: .whitespaces)) { return number }
        default:
            break
        }
        DocumentValues.warnOnce(
            .notANumber(key: key),
            "getFloat(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not a number. "
                + "Reading it as NaN (said once per key)")
        return .nan
    }

    /// キーの値を、入れ子のオブジェクトとして読む。
    ///
    /// <!-- example: 文脈 var weather: JSONObject! -->
    /// ```swift
    /// let main = weather.getJSONObject("main")
    /// let warmth = constrain(norm(main.getFloat("temp"), -10, 35), 0, 1)
    /// background(lerp(70, 240, warmth), lerp(130, 140, warmth), lerp(220, 60, warmth))
    /// ```
    ///
    /// **オブジェクトでないときは空のオブジェクトを返し、初回だけ理由を知らせる** — キーが
    /// 無い・値が数や文字や配列のどれでも (キーごとに 1 度)。空のオブジェクトから
    /// ``getFloat(_:)`` で読むと NaN になるので、繋いだまま書いてよい。
    public func getJSONObject(_ key: String) -> JSONObject {
        guard let value = member(key, call: "getJSONObject") else { return JSONObject([:]) }
        if case .object(let members) = value { return JSONObject(members) }
        DocumentValues.warnOnce(
            .notAnObject(key: key),
            "getJSONObject(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not "
                + "an object. Reading it as an empty object (said once per key)")
        return JSONObject([:])
    }

    /// キーの値。無ければ初回だけ知らせて `nil`。
    private func member(_ key: String, call: String) -> JSONValue? {
        if let value = members[key] { return value }
        DocumentValues.warnOnce(
            .noKey(key),
            "\(call)(\"\(key)\"): the JSON object has no key \"\(key)\". "
                + DocumentValues.listing("Its keys are", members.keys))
        return nil
    }
}
