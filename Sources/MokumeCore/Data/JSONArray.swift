// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON の配列 (`[ 値, … ]`)。オブジェクトの中の配列は ``JSONObject/getJSONArray(_:)`` で、最上位が
/// 配列の JSON は ``SketchPart/loadJSONArray(_:)`` で読んで作り、`for-in` で回すか、番号で値を
/// 取り出す。
///
/// <!-- example: 文脈 var quakes: JSONObject? -->
/// ```swift
/// func setup() throws {
///     // 応答は { "features": [ { "properties": { "mag": 5.5, "place": "Off the coast" },
///     //                         "geometry": { "coordinates": [142.4, 38.3, 10] } }, … ] } の形
///     quakes = try loadJSONObject("data/quakes.geojson")
/// }
///
/// func draw() {
///     background(23, 26, 31)
///     guard let quakes else { return }
///     for feature in quakes.getJSONArray("features") {
///         let coordinates = feature.getJSONObject("geometry").getJSONArray("coordinates")
///         let properties = feature.getJSONObject("properties")
///         let x = map(coordinates.getFloat(0), -180, 180, 0, width)
///         let y = map(coordinates.getFloat(1), 90, -90, 0, height)
///         circle(x, y, properties.getFloat("mag") * 4)
///         if properties.getFloat("mag") > 5 { text(properties.getString("place"), x + 8, y) }
///     }
/// }
/// ```
///
/// その日の地震の GeoJSON を、経緯度の位置に規模の大きさの円で描く。大きな地震だけ地名を添える。
///
/// ## 要素は ``JSONObject`` として回る
///
/// 配列は `RandomAccessCollection` で、要素の型は ``JSONObject`` である。`for-in`・`count`・`isEmpty`・
/// `first`・`map`・`enumerated()` がそのまま使える。**数え方は `count` だけ**で、`size()` は持たない。
/// オブジェクトでない要素 (`[1, 2, 3]` の数) をオブジェクトとして取り出すと、空のオブジェクトになって
/// 知らせる。数・文字・真偽の配列は、番号で ``getFloat(_:)``・``getString(_:)``・``getInt(_:)``・
/// ``getBoolean(_:)`` と読む。
///
/// ## 値の型である
///
/// 代入すると写しになる (``JSONObject`` と同じ)。読むだけで、書き換える口は持たない。
///
/// ## 値が無くても落ちない
///
/// 範囲の外の番号や、思っていたのと違う種類の要素を取り出しても、取り出す口は落ちない。
/// ``JSONObject`` の欠けたキーと同じく、読もうとした種類の空の値 (``getFloat(_:)`` は NaN、
/// ``getString(_:)`` は空の文字、``getInt(_:)`` は 0、``getBoolean(_:)`` は `false`、
/// オブジェクトは空のオブジェクト、配列は空の配列) を返し、**初回だけ理由を知らせる**
/// ([ADR-0020] 決定 5)。知らせるのは、口の名前と事情 (範囲の外・種類の違い) の組ごとに 1 度で、番号ごと
/// ではない (大きな配列でも、知らせは口ごとに高々 2 つ)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public struct JSONArray: Equatable, Sendable {
    /// 要素。
    let items: [JSONValue]

    init(_ items: [JSONValue]) {
        self.items = items
    }

    // MARK: - 番号で取り出す

    /// 番号の要素を、数として読む。
    ///
    /// <!-- example: 文脈 var coordinates: JSONArray! -->
    /// ```swift
    /// let x = map(coordinates.getFloat(0), -180, 180, 0, width)
    /// let y = map(coordinates.getFloat(1), 90, -90, 0, height)
    /// circle(x, y, 8)
    /// ```
    ///
    /// 読み方は ``JSONObject/getFloat(_:)`` と同じ (数の値はそのまま、数の文字は 10 進の綴りだけを
    /// 数として読む)。**数にならないときは NaN を返し、初回だけ理由を知らせる** — 範囲の外の番号・
    /// 要素が数でないのどちらでも (口ごとに 1 度)。
    public func getFloat(_ index: Int) -> Float {
        guard let value = element(index, call: "getFloat", reading: "NaN") else { return .nan }
        if let number = value.asFloat { return number }
        wrongKind(index, value, call: "getFloat", expected: "a number", reading: "NaN")
        return .nan
    }

    /// 番号の要素を、整数として読む。
    ///
    /// <!-- example: 文脈 var counts: JSONArray! -->
    /// ```swift
    /// for i in 0..<counts.count {
    ///     rect(20 + Float(i) * 30, height - 20, 24, -Float(counts.getInt(i)) * 4)
    /// }
    /// ```
    ///
    /// 読み方は ``JSONObject/getInt(_:)`` と同じ (**丸めない**。`2` と `2.0` は `2`、`2.5` は `0`)。
    /// **整数にならないときは 0 を返し、初回だけ理由を知らせる** — 範囲の外の番号・整数でない値の
    /// どちらでも (口ごとに 1 度)。
    public func getInt(_ index: Int) -> Int {
        guard let value = element(index, call: "getInt", reading: "0") else { return 0 }
        if let number = value.asInt { return number }
        wrongKind(index, value, call: "getInt", expected: "an integer that fits in an Int", reading: "0")
        return 0
    }

    /// 番号の要素を、文字として読む。
    ///
    /// <!-- example: 文脈 var names: JSONArray! -->
    /// ```swift
    /// for i in 0..<names.count {
    ///     text(names.getString(i), 20, 30 + Float(i) * 20)
    /// }
    /// ```
    ///
    /// 読み方は ``JSONObject/getString(_:)`` と同じ (文字の値だけを読む)。**文字にならないときは空の
    /// 文字を返し、初回だけ理由を知らせる** — 範囲の外の番号・要素が文字でないのどちらでも (口ごとに 1 度)。
    public func getString(_ index: Int) -> String {
        guard let value = element(index, call: "getString", reading: "an empty string") else { return "" }
        if let text = value.asString { return text }
        wrongKind(index, value, call: "getString", expected: "a string", reading: "an empty string")
        return ""
    }

    /// 番号の要素を、真偽として読む。
    ///
    /// <!-- example: 文脈 var flags: JSONArray! -->
    /// ```swift
    /// for i in 0..<flags.count {
    ///     fill(flags.getBoolean(i) ? 255 : 60)
    ///     circle(20 + Float(i) * 24, height / 2, 16)
    /// }
    /// ```
    ///
    /// 読み方は ``JSONObject/getBoolean(_:)`` と同じ (`true` / `false` だけを読む)。**真偽にならない
    /// ときは `false` を返し、初回だけ理由を知らせる** — 範囲の外の番号・要素が真偽でないのどちらでも
    /// (口ごとに 1 度)。
    public func getBoolean(_ index: Int) -> Bool {
        guard let value = element(index, call: "getBoolean", reading: "false") else { return false }
        if let flag = value.asBool { return flag }
        wrongKind(index, value, call: "getBoolean", expected: "a boolean", reading: "false")
        return false
    }

    /// 番号の要素を、オブジェクトとして取り出す。
    ///
    /// <!-- example: 文脈 var features: JSONArray! -->
    /// ```swift
    /// let first = features.getJSONObject(0)
    /// text(first.getString("id"), 20, 40)
    /// ```
    ///
    /// ``subscript(_:)`` と同じ。**オブジェクトでないときは空のオブジェクトを返し、初回だけ理由を
    /// 知らせる** — 範囲の外の番号・要素がオブジェクトでないのどちらでも (口ごとに 1 度)。
    public func getJSONObject(_ index: Int) -> JSONObject {
        guard let value = element(index, call: "getJSONObject", reading: "an empty object") else {
            return JSONObject([:])
        }
        if case .object(let members) = value { return JSONObject(members) }
        wrongKind(
            index, value, call: "getJSONObject", expected: "an object", reading: "an empty object")
        return JSONObject([:])
    }

    /// 番号の要素を、配列として読む。配列の配列 (GeoJSON の多角形の `coordinates` など) を降りるときに使う。
    ///
    /// <!-- example: 文脈 var ring: JSONArray! -->
    /// ```swift
    /// let corner = ring.getJSONArray(0)
    /// circle(corner.getFloat(0), corner.getFloat(1), 8)
    /// ```
    ///
    /// **配列でないときは空の配列を返し、初回だけ理由を知らせる** — 範囲の外の番号・要素が配列でない
    /// のどちらでも (口ごとに 1 度)。
    public func getJSONArray(_ index: Int) -> JSONArray {
        guard let value = element(index, call: "getJSONArray", reading: "an empty array") else {
            return JSONArray([])
        }
        if case .array(let nested) = value { return JSONArray(nested) }
        wrongKind(index, value, call: "getJSONArray", expected: "an array", reading: "an empty array")
        return JSONArray([])
    }

    // MARK: - 内部

    /// 番号の要素。範囲の外なら初回だけ知らせて `nil`。
    private func element(_ index: Int, call: String, reading: String) -> JSONValue? {
        if items.indices.contains(index) { return items[index] }
        DocumentValues.warnOnce(
            .arrayElement(call: call, problem: .outOfRange),
            "\(call)(\(index)): the JSON array has \(items.count) element\(items.count == 1 ? "" : "s"), "
                + "so there is no element \(index). Reading it as \(reading) (said once per call)")
        return nil
    }

    /// 要素の種類が違うことを、初回だけ知らせる。
    private func wrongKind(
        _ index: Int, _ value: JSONValue, call: String, expected: String, reading: String
    ) {
        DocumentValues.warnOnce(
            .arrayElement(call: call, problem: .wrongKind),
            "\(call)(\(index)): element \(index) of the JSON array is \(value.spoken), which is not "
                + "\(expected). Reading it as \(reading) (said once per call)")
    }
}

// MARK: - Collection

/// 配列を `for-in` で回し、`count`・`first`・`map` などを使えるようにする。
///
/// **適合は main actor の上である** (スケッチの `setup()`・`draw()` と同じ場所)。要素の取り出しが
/// 知らせの控え (main actor の上) へ書くので、隔離の外へは渡さない。
extension JSONArray: @MainActor RandomAccessCollection {
    /// 先頭の番号 (0)。
    public var startIndex: Int { 0 }

    /// 末尾の次の番号 (`count` と同じ)。
    public var endIndex: Int { items.count }

    /// 番号の要素を、オブジェクトとして取り出す。
    ///
    /// **範囲の外の番号でも落ちない** (`Collection` の約束より緩い)。空のオブジェクトを返し、初回だけ
    /// 知らせる。オブジェクトでない要素も同じ。番号を ``getJSONObject(_:)`` と同じに読むので、
    /// `for-in` で回したときの知らせもその口の名前で出る。
    public subscript(position: Int) -> JSONObject {
        getJSONObject(position)
    }
}
