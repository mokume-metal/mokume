// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON の配列 (`[ 値, … ]`)。オブジェクトの中の配列は ``JSONObject/getJSONArray(_:)`` で、最上位が
/// 配列の JSON は ``SketchPart/loadJSONArray(_:)`` で読んで作り、`for-in` で回すか、番号で値を
/// 取り出す。空から作って (``init()``) 値を足し (``append(_:)-(Int)``)、``SketchPart/saveJSONArray(_:_:)``
/// で書き出すこともできる。
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
/// 代入すると写しになる (``JSONObject`` と同じ)。書き換える口 (``append(_:)-(Int)``・``remove(_:)``・
/// ``setFloat(_:_:)`` ほか) は `mutating` で、`var` で持った配列にだけ書ける。入れ子の配列やオブジェクトへは
/// 直に書けないので、写しを書き換えて ``setJSONArray(_:_:)``・``setJSONObject(_:_:)`` で戻す
/// (``JSONObject`` の「値の型である」と同じ)。
///
/// **範囲の外の番号には書かず、初回だけ理由を知らせる** (2026-10-31 の決定)。Processing は間を `null` で
/// 埋めて伸ばすが、番号の打ち間違いが黙って長い配列を作らないようにする。伸ばすのは ``append(_:)-(Int)``
/// である。
/// 読み出しは main actor の上にあるので、`DispatchQueue.concurrentPerform` などで並列に回すときは、分ける前に値へ写しておく (形は ``map(_:_:_:_:_:)`` の説明)。
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
    var items: [JSONValue]

    init(_ items: [JSONValue]) {
        self.items = items
    }

    /// 空の配列を作る。値は ``append(_:)-(Int)`` で足し、``SketchPart/saveJSONArray(_:_:)`` で書き出す。
    /// Processing の `new JSONArray()`。
    ///
    /// <!-- example: 文脈 var clicks = JSONArray() -->
    /// ```swift
    /// func mousePressed() {
    ///     var point = JSONObject()
    ///     point.setFloat("x", mouseX)
    ///     point.setFloat("y", mouseY)
    ///     clicks.append(point)
    ///     try? saveJSONArray(clicks, "out/clicks.json")
    /// }
    /// ```
    public init() {
        items = []
    }

    // MARK: - 足す・除く

    /// 末尾に整数を足す。整数の綴り (`2`) で書かれる。
    ///
    /// <!-- example: 文脈 var counts = JSONArray() -->
    /// ```swift
    /// counts.append(frameCount)
    /// ```
    public mutating func append(_ value: Int) {
        items.append(.integer(value))
    }

    /// 末尾に数を足す。書き出すと `Float` の最も短い綴りになる (``JSONObject/setFloat(_:_:)`` と同じ)。
    ///
    /// <!-- example: 文脈 var coordinates = JSONArray() -->
    /// ```swift
    /// coordinates.append(mouseX)
    /// coordinates.append(mouseY)
    /// ```
    ///
    /// **NaN と無限は足さず、初回だけ理由を知らせる** (口ごとに 1 度。``JSONObject/setFloat(_:_:)`` と同じ
    /// 決まり)。
    public mutating func append(_ value: Float) {
        guard finite(value, call: "append", index: nil) else { return }
        items.append(.number(shortest: value))
    }

    /// 末尾に文字を足す。
    ///
    /// <!-- example: 文脈 var names = JSONArray() -->
    /// ```swift
    /// names.append("Sapporo")
    /// ```
    public mutating func append(_ value: String) {
        items.append(.string(value))
    }

    /// 末尾に真偽を足す。
    ///
    /// <!-- example: 文脈 var flags = JSONArray() -->
    /// ```swift
    /// flags.append(mouseX > width / 2)
    /// ```
    public mutating func append(_ value: Bool) {
        items.append(.bool(value))
    }

    /// 末尾にオブジェクトを足す。足すのは渡した時点の写しである。
    ///
    /// <!-- example: 文脈 var features = JSONArray() -->
    /// ```swift
    /// var feature = JSONObject()
    /// feature.setString("place", "Off the coast")
    /// features.append(feature)
    /// ```
    public mutating func append(_ value: JSONObject) {
        items.append(.object(value.members))
    }

    /// 末尾に配列を足す。配列の配列 (GeoJSON の `coordinates`) はこれで組む。足すのは渡した時点の写しである。
    ///
    /// <!-- example: 文脈 var ring = JSONArray() -->
    /// ```swift
    /// var corner = JSONArray()
    /// corner.append(142.4 as Float)
    /// corner.append(38.3 as Float)
    /// ring.append(corner)
    /// ```
    public mutating func append(_ value: JSONArray) {
        items.append(.array(value.items))
    }

    /// 番号の要素を除く。後ろの要素は 1 つずつ前へ詰まる。
    ///
    /// <!-- example: 文脈 var history = JSONArray() -->
    /// ```swift
    /// history.append(mouseX)
    /// if history.count > 60 { history.remove(0) }
    /// ```
    ///
    /// 除いた値は返さない。要素の種類が決まらず、`Any` を面に出さないため ([ADR-0020] 決定 6)。値が要るなら
    /// 先に ``getFloat(_:)`` などで読む。
    ///
    /// **範囲の外の番号には何もせず、初回だけ理由を知らせる** (口ごとに 1 度)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public mutating func remove(_ index: Int) {
        guard inRange(index, call: "remove", doing: "Nothing was removed") else { return }
        items.remove(at: index)
    }

    // MARK: - 番号へ書く

    /// 番号の要素を真偽で置き換える。値の種類が変わってもよい。
    ///
    /// <!-- example: 文脈 var flags: JSONArray! -->
    /// ```swift
    /// flags.setBoolean(0, true)
    /// ```
    ///
    /// **範囲の外の番号には書かず、初回だけ理由を知らせる** (口ごとに 1 度。2026-10-31 の決定)。伸ばすのは
    /// ``append(_:)-(Bool)`` である。
    public mutating func setBoolean(_ index: Int, _ value: Bool) {
        set(index, .bool(value), call: "setBoolean")
    }

    /// 番号の要素を数で置き換える。値の種類が変わってもよい。
    ///
    /// <!-- example: 文脈 var levels: JSONArray! -->
    /// ```swift
    /// levels.setFloat(0, mouseX / width)
    /// ```
    ///
    /// 範囲の外の番号の扱いは ``setBoolean(_:_:)`` と同じ。**NaN と無限は書かず、初回だけ理由を知らせる**
    /// (``append(_:)-(Float)`` と同じ決まり)。
    public mutating func setFloat(_ index: Int, _ value: Float) {
        guard inRange(index, call: "setFloat", doing: "Nothing was written"),
            finite(value, call: "setFloat", index: index)
        else { return }
        items[index] = .number(shortest: value)
    }

    /// 番号の要素を整数で置き換える。整数の綴り (`2`) で書かれる。
    ///
    /// <!-- example: 文脈 var counts: JSONArray! -->
    /// ```swift
    /// counts.setInt(0, counts.getInt(0) + 1)
    /// ```
    ///
    /// 範囲の外の番号の扱いは ``setBoolean(_:_:)`` と同じ。
    public mutating func setInt(_ index: Int, _ value: Int) {
        set(index, .integer(value), call: "setInt")
    }

    /// 番号の要素を文字で置き換える。
    ///
    /// <!-- example: 文脈 var names: JSONArray! -->
    /// ```swift
    /// names.setString(0, "Naha")
    /// ```
    ///
    /// 範囲の外の番号の扱いは ``setBoolean(_:_:)`` と同じ。
    public mutating func setString(_ index: Int, _ value: String) {
        set(index, .string(value), call: "setString")
    }

    /// 番号の要素をオブジェクトで置き換える。入れ子のオブジェクトは、写しを書き換えてここで戻す。
    ///
    /// <!-- example: 文脈 var features: JSONArray! -->
    /// ```swift
    /// var first = features.getJSONObject(0)
    /// first.setString("place", "Off the coast")
    /// features.setJSONObject(0, first)
    /// ```
    ///
    /// 範囲の外の番号の扱いは ``setBoolean(_:_:)`` と同じ。
    public mutating func setJSONObject(_ index: Int, _ value: JSONObject) {
        set(index, .object(value.members), call: "setJSONObject")
    }

    /// 番号の要素を配列で置き換える。入れ子の配列は、写しを書き換えてここで戻す。
    ///
    /// <!-- example: 文脈 var ring: JSONArray! -->
    /// ```swift
    /// var corner = ring.getJSONArray(0)
    /// corner.setFloat(0, 140)
    /// ring.setJSONArray(0, corner)
    /// ```
    ///
    /// 範囲の外の番号の扱いは ``setBoolean(_:_:)`` と同じ。
    public mutating func setJSONArray(_ index: Int, _ value: JSONArray) {
        set(index, .array(value.items), call: "setJSONArray")
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

    /// 番号の要素が `null` か。**範囲の外の番号も `true`** (Processing の `isNull()` と同じ)。
    ///
    /// <!-- example: 文脈 var readings: JSONArray! -->
    /// ```swift
    /// for i in 0..<readings.count where !readings.isNull(i) {
    ///     circle(20 + Float(i) * 24, height - readings.getFloat(i), 8)
    /// }
    /// ```
    ///
    /// 番号が範囲の中かは `count` で分かる。**知らせない** — 値が欠けているかもしれないことを分かって
    /// 尋ねる口である (``JSONObject/isNull(_:)`` と同じ)。
    public func isNull(_ index: Int) -> Bool {
        guard items.indices.contains(index) else { return true }
        return items[index] == .null
    }

    // MARK: - 内部

    /// 書く口の共通の道。範囲の外なら書かずに、口ごとに 1 度知らせる。
    private mutating func set(_ index: Int, _ value: JSONValue, call: String) {
        guard inRange(index, call: call, doing: "Nothing was written") else { return }
        items[index] = value
    }

    /// 書き換える番号が範囲の中か。外なら初回だけ知らせて `false`。
    private func inRange(_ index: Int, call: String, doing outcome: String) -> Bool {
        if items.indices.contains(index) { return true }
        DocumentValues.warnOnce(
            .arrayElement(call: call, problem: .outOfRange),
            "\(call)(\(index)): the JSON array has \(items.count) element\(items.count == 1 ? "" : "s"), "
                + "so there is no element \(index). \(outcome) (said once per call)")
        return false
    }

    /// 書く数が有限か。NaN と無限なら初回だけ知らせて `false` (JSON には綴りが無い)。
    private func finite(_ value: Float, call: String, index: Int?) -> Bool {
        if value.isFinite { return true }
        let place = index.map { "\($0), " } ?? ""
        DocumentValues.warnOnce(
            .arrayElement(call: call, problem: .notFinite),
            "\(call)(\(place)\(value)): JSON has no spelling for \(value), so nothing was written "
                + "(said once per call)")
        return false
    }

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
