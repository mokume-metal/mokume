// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON のオブジェクト (`{ "キー": 値, … }`)。ファイルか URL から読んで作り
/// (``SketchPart/loadJSONObject(_:)``・``SketchPart/parseJSONObject(_:)``)、キーで値を取り出す。
///
/// <!-- example: 文脈 var temp: Float? -->
/// ```swift
/// func setup() throws {
///     // 応答は { "name": "Sapporo", "main": { "temp": -3.5 } } の形
///     let weather = try loadJSONObject("data/weather.json")
///     temp = weather.getJSONObject("main").getFloat("temp")
/// }
/// ```
///
/// ## 型を書かずに読む
///
/// 読む前に応答の形を型として宣言しなくてよい。欲しい値を、キーを辿って取り出す
/// (``getJSONObject(_:)`` で入れ子へ降り、``getFloat(_:)`` で数を、``getString(_:)`` で文字を取る。
/// 配列は ``getJSONArray(_:)`` で ``JSONArray`` にして回す)。最上位が配列の JSON は
/// ``SketchPart/loadJSONArray(_:)`` で読む。
///
/// ## 値の型である
///
/// 代入すると写しになる (``Table`` と同じ)。読むだけで、書き換える口は持たない。
/// 読み出しは main actor の上にあるので、`DispatchQueue.concurrentPerform` などで並列に回すときは、分ける前に値へ写しておく (形は ``map(_:_:_:_:_:)`` の説明)。
///
/// ## 値が無くても落ちない
///
/// 無いキーや、思っていたのと違う種類の値を取り出しても、取り出す口は落ちない。``getFloat(_:)``
/// は NaN、``getString(_:)`` は空の文字、``getInt(_:)`` は 0、``getBoolean(_:)`` は `false`、
/// ``getJSONObject(_:)`` は空のオブジェクト、``getJSONArray(_:)`` は空の配列を返し、**キーごとに
/// 1 度だけ理由を知らせる** ([ADR-0020] 決定 5)。だから入れ子を繋いだまま書ける — 途中のキーが
/// 欠けていれば、最後の数が NaN になり、知らせが欠けたキーを名指す。キーがあるかを先に確かめたい
/// ときは ``hasKey(_:)`` で、知らせずに分かる。
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
    /// 数の値はそのまま、数の文字 (`"18.5"`) は数として読む。数の文字とするのは **10 進の綴り
    /// だけ** (`"-2"`・`"+5"`・`".5"`・`"1e3"`) で、前後の空白は改行も含めて落とす。`Float` に
    /// 収まらない数 (`1e39`・`"1e39"`) は無限大になる。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — キーが無い・値が
    /// `true` / `false` / `null`・オブジェクト・配列・数でない文字のどれでも (キーごとに 1 度)。
    /// 文字の `"nan"`・`"NaN"`・`"inf"`・`"Infinity"`・16 進 (`"0x10"`) も、数でない文字である。
    /// 読み取りは落ちない ([ADR-0020] 決定 5)。NaN は表の ``TableRow/getFloat(_:)-(String)`` が
    /// 欠けた値に返すものと同じで、0 のように黙って別の値に化けない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getFloat(_ key: String) -> Float {
        guard let value = member(key, call: "getFloat") else { return .nan }
        if let number = value.asFloat { return number }
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

    /// キーの値を、文字として読む。
    ///
    /// <!-- example: 文脈 var weather: JSONObject! -->
    /// ```swift
    /// let name = weather.getString("name")
    /// text(name, 20, 40)
    /// ```
    ///
    /// **文字の値だけを読む。** 数や真偽を綴りにして返すことはしない (`18.5` は文字ではない)。
    ///
    /// **文字にならないときは空の文字を返し、初回だけ理由を知らせる** — キーが無い・値が文字
    /// でない (数・`true` / `false` / `null`・オブジェクト・配列) のどれでも (キーごとに 1 度)。
    /// 読み取りは落ちない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getString(_ key: String) -> String {
        guard let value = member(key, call: "getString") else { return "" }
        if let text = value.asString { return text }
        DocumentValues.warnOnce(
            .notAString(key: key),
            "getString(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not a string. "
                + "Reading it as an empty string (said once per key)")
        return ""
    }

    /// キーの値を、整数として読む。
    ///
    /// <!-- example: 文脈 var quake: JSONObject! -->
    /// ```swift
    /// let stations = quake.getInt("nst")
    /// for i in 0..<stations {
    ///     circle(20 + Float(i) * 12, height / 2, 8)
    /// }
    /// ```
    ///
    /// **丸めない** — `2` と `2.0` は `2` で、`2.5` は `0` を返して知らせる (黙って別の値を返さない。
    /// OSC の `int(_:)` と同じく、整数の値だけを読む)。小数が要るときは ``getFloat(_:)``。
    /// 数の文字は、``getFloat(_:)`` と同じ 10 進の綴りで整数の値のもの (`"3"`・`"1e3"`) だけを読む。
    ///
    /// **整数にならないときは 0 を返し、初回だけ理由を知らせる** — キーが無い・整数でない数・`Int`
    /// に収まらない数・数でない値のどれでも (キーごとに 1 度)。読み取りは落ちない
    /// ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getInt(_ key: String) -> Int {
        guard let value = member(key, call: "getInt") else { return 0 }
        if let number = value.asInt { return number }
        DocumentValues.warnOnce(
            .notAnInteger(key: key),
            "getInt(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not an integer "
                + "that fits in an Int. Reading it as 0 (said once per key)")
        return 0
    }

    /// キーの値を、真偽として読む。
    ///
    /// <!-- example: 文脈 var quake: JSONObject! -->
    /// ```swift
    /// if quake.getBoolean("tsunami") {
    ///     background(200, 40, 40)
    /// }
    /// ```
    ///
    /// **`true` / `false` だけを読む。** 数の `1` / `0` や文字の `"true"` は真偽ではない。
    ///
    /// **真偽にならないときは `false` を返し、初回だけ理由を知らせる** — キーが無い・値が真偽でない
    /// のどれでも (キーごとに 1 度)。読み取りは落ちない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getBoolean(_ key: String) -> Bool {
        guard let value = member(key, call: "getBoolean") else { return false }
        if let flag = value.asBool { return flag }
        DocumentValues.warnOnce(
            .notABoolean(key: key),
            "getBoolean(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not a boolean. "
                + "Reading it as false (said once per key)")
        return false
    }

    /// キーの値を、配列として読む。
    ///
    /// <!-- example: 文脈 var quakes: JSONObject! -->
    /// ```swift
    /// for feature in quakes.getJSONArray("features") {
    ///     let magnitude = feature.getJSONObject("properties").getFloat("mag")
    ///     circle(width / 2, height / 2, magnitude * 8)
    /// }
    /// ```
    ///
    /// 返る ``JSONArray`` は `for-in` で回せる。
    ///
    /// **配列でないときは空の配列を返し、初回だけ理由を知らせる** — キーが無い・値が配列でない
    /// のどれでも (キーごとに 1 度)。空の配列は何も回さないので、繋いだまま書いてよい。
    public func getJSONArray(_ key: String) -> JSONArray {
        guard let value = member(key, call: "getJSONArray") else { return JSONArray([]) }
        if case .array(let items) = value { return JSONArray(items) }
        DocumentValues.warnOnce(
            .notAnArray(key: key),
            "getJSONArray(\"\(key)\"): the value of \"\(key)\" is \(value.spoken), which is not an "
                + "array. Reading it as an empty array (said once per key)")
        return JSONArray([])
    }

    /// そのキーがあるか。値が `null` でも、キーがあれば `true`。
    ///
    /// <!-- example: 文脈 var weather: JSONObject! -->
    /// ```swift
    /// if weather.hasKey("rain") {
    ///     fill(80, 120, 220)
    /// }
    /// ```
    ///
    /// **知らせない** — キーが無いかもしれないことを分かって尋ねる口である。
    public func hasKey(_ key: String) -> Bool {
        members[key] != nil
    }

    /// キーの一覧。**文字の順に並べる。**
    ///
    /// <!-- example: 文脈 var weather: JSONObject! -->
    /// ```swift
    /// for (i, key) in weather.keys.enumerated() {
    ///     text(key, 20, 30 + Float(i) * 20)
    /// }
    /// ```
    ///
    /// Swift の辞書の順は実行ごとに変わるので、そのまま渡すと同じ JSON から違う絵ができる。
    /// 文字の順にそろえてあるので、何度走らせても同じ並びになる (JSON のオブジェクトは書かれた順を
    /// 約束しないので、書かれた順では返さない)。
    public var keys: [String] {
        members.keys.sorted()
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
