// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// XML の要素 1 つ (`<star x="120" y="80"/>`)。ファイルか URL から読んで根の要素を作り
/// (``SketchPart/loadXML(_:)``・届いた文字からは ``SketchPart/parseXML(_:)``)、子の要素を名前で
/// 取り出し、属性を読む。
///
/// <!-- example: 文脈 var sky: XML? -->
/// ```swift
/// func setup() throws {
///     // <sky><star x="120" y="80" size="6"/> … </sky>
///     sky = try loadXML("data/constellation.xml")
/// }
///
/// func draw() {
///     background(12, 16, 32)
///     noStroke()
///     for star in sky?.getChildren("star") ?? [] {
///         circle(star.getFloat("x"), star.getFloat("y"), star.getFloat("size"))
///     }
/// }
/// ```
///
/// RSS のような、要素の中に文字がある XML も読める。``getChild(_:)`` で子へ降り、``getContent()`` で
/// 要素の文字を、``getString(_:)`` で属性の文字を取る。
///
/// <!-- example: 文脈 var feed: XML? -->
/// ```swift
/// func setup() throws {
///     // <rss><channel><item><title>Nightfall</title></item> … </channel></rss>
///     feed = try loadXML("data/news.xml")
/// }
///
/// func draw() {
///     background(23, 26, 31)
///     for (i, item) in (feed?.getChild("channel").getChildren("item") ?? []).enumerated() {
///         text(item.getChild("title").getContent(), 20, 30 + Float(i) * 24)
///     }
/// }
/// ```
///
/// ## 値の型である
///
/// 代入すると写しになる (``Table`` と同じ)。読むだけで、書き換える口は持たない。
/// 読み出しは main actor の上にあるので、`DispatchQueue.concurrentPerform` などで並列に回すときは、分ける前に値へ写しておく (形は ``map(_:_:_:_:_:)`` の説明)。
///
/// ## 値が無くても落ちない
///
/// 無い属性や数でない属性を ``getFloat(_:)`` で読むと NaN を、無い属性を ``getString(_:)`` で読むと空の
/// 文字を返し、無い子を ``getChild(_:)`` で取ると空の要素を返して、**初回だけ理由を知らせる**
/// ([ADR-0020] 決定 5)。空の要素は子も属性も文字も持たないので、繋いだまま書いてよい。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public struct XML: Equatable, Sendable {
    let element: XMLFile.Element

    init(_ element: XMLFile.Element) {
        self.element = element
    }

    /// 要素の名前 (`<star …>` なら `"star"`)。
    ///
    /// <!-- example: 文脈 var sky: XML! -->
    /// ```swift
    /// for (i, child) in sky.getChildren().enumerated() {
    ///     text(child.getName(), 20, 30 + Float(i) * 20)
    /// }
    /// ```
    ///
    /// 名前空間の前置きは名前の一部として返す (`s:b`)。``getChild(_:)`` が返した空の要素 (合う子が
    /// 無かったとき) の名前は空の文字である。
    public func getName() -> String {
        element.name
    }

    /// すべての子の要素を、書かれた順に並べる。
    ///
    /// <!-- example: 文脈 var sky: XML! -->
    /// ```swift
    /// for child in sky.getChildren() where child.getName() == "star" {
    ///     circle(child.getFloat("x"), child.getFloat("y"), 6)
    /// }
    /// ```
    ///
    /// 見るのは**直下の子だけ**で、孫は入らない (``getChildren(_:)`` と同じ)。名前を選ばずに全部を取るので、
    /// 違う名前の子が混ざった要素を書かれた順に回せる。数は `count`、有無は `isEmpty`、名前の並びは
    /// `map { $0.getName() }`、番号の子は `getChildren()[i]` で引く。
    ///
    /// 子が無ければ空の並びを返し、**知らせない**。
    public func getChildren() -> [XML] {
        element.children.map(XML.init)
    }

    /// その名前の子の要素を、書かれた順に並べる。
    ///
    /// <!-- example: 文脈 var sky: XML! -->
    /// ```swift
    /// let stars = sky.getChildren("star")
    /// for (i, star) in stars.enumerated() where i > 0 {
    ///     line(stars[i - 1].getFloat("x"), stars[i - 1].getFloat("y"), star.getFloat("x"), star.getFloat("y"))
    /// }
    /// ```
    ///
    /// 見るのは**直下の子だけ**で、孫は入らない。名前は前置きごと比べる (`s:b`)。
    ///
    /// **合う子が無ければ空の並びを返す。** 子が 1 つも無い要素は黙って空を返し、他の名前の子が
    /// あるのに 1 つも合わないときだけ、在る子の名前を添えて初回だけ知らせる (名前ごとに 1 度)。
    /// 綴りの誤りで何も描かれないとき、理由が分かるように。
    public func getChildren(_ name: String) -> [XML] {
        let matched = element.children.filter { $0.name == name }
        if matched.isEmpty, !element.children.isEmpty {
            DocumentValues.warnOnce(
                .noChild(element: element.name, name: name),
                "getChildren(\"\(name)\"): <\(element.name)> has no child named \"\(name)\". "
                    + DocumentValues.listing(
                        "Its children are named", Set(element.children.map(\.name))))
        }
        return matched.map(XML.init)
    }

    /// その名前の子の要素のうち、書かれた最初の 1 つ。
    ///
    /// <!-- example: 文脈 var feed: XML! -->
    /// ```swift
    /// let channel = feed.getChild("channel")
    /// text(channel.getChild("title").getContent(), 20, 30)
    /// ```
    ///
    /// 見るのは**直下の子だけ**で、孫は入らない (``getChildren(_:)`` と同じ)。同じ名前の子が並ぶとき
    /// は、全部を取るのが ``getChildren(_:)``。
    ///
    /// **合う子が無ければ空の要素を返し、初回だけ理由を知らせる** (要素の名前と子の名前の組ごとに
    /// 1 度)。子が 1 つも無い要素でも知らせる — ``getChildren(_:)`` と違い、1 つあるはずと尋ねる口
    /// だからである。
    public func getChild(_ name: String) -> XML {
        if let found = element.children.first(where: { $0.name == name }) { return XML(found) }
        DocumentValues.warnOnce(
            .noChild(element: element.name, name: name),
            "getChild(\"\(name)\"): <\(element.name)> has no child named \"\(name)\". "
                + (element.children.isEmpty
                    ? "It has no children"
                    : DocumentValues.listing(
                        "Its children are named", Set(element.children.map(\.name))))
                + ". Reading it as an empty element (said once per name)")
        return XML(XMLFile.Element(name: "", attributes: [:], children: []))
    }

    /// 要素の直下の文字。
    ///
    /// <!-- example: 文脈 var item: XML! -->
    /// ```swift
    /// text(item.getChild("title").getContent(), 20, 30)
    /// ```
    ///
    /// **書かれたままの文字を返す** — 前後の空白も、字下げの改行もそのまま残る。CDATA (`<![CDATA[…]]>`)
    /// の中の文字も含み、実体参照 (`&amp;`) は解いた値になる。子の要素の中の文字は含まない (子へ降りて
    /// 読む)。文字が無い要素は空の文字を返し、**知らせない** — 要素の中身が空なのは、読み間違いでは
    /// なく文書の形である。
    public func getContent() -> String {
        element.content
    }

    /// 要素の直下の文字を、数として読む (`<temp>-3.5</temp>` なら -3.5)。
    ///
    /// <!-- example: 文脈 var reading: XML! -->
    /// ```swift
    /// let temp = reading.getChild("temp").getFloatContent()
    /// rect(20, height / 2, temp * 10, 20)
    /// ```
    ///
    /// 読み方は ``getFloat(_:)`` と同じで、数とするのは **10 進の綴りだけ**、前後の空白 (字下げの改行も)
    /// は落とす。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — 文字が無い・数でない文字のどちらでも
    /// (要素の名前ごとに 1 度)。読み取りは落ちない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getFloatContent() -> Float {
        if let number = DecimalText.float(element.content) { return number }
        DocumentValues.warnOnce(
            .contentNotANumber(element: element.name),
            "getFloatContent(): <\(element.name)> holds \(spokenContent), which is not a number. "
                + "Reading it as NaN (said once per element name)")
        return .nan
    }

    /// 要素の直下の文字を、整数として読む (`<count>12</count>` なら 12)。
    ///
    /// <!-- example: 文脈 var item: XML! -->
    /// ```swift
    /// let count = item.getChild("count").getIntContent()
    /// for i in 0..<count {
    ///     circle(20 + Float(i) * 12, height / 2, 8)
    /// }
    /// ```
    ///
    /// **丸めない** — `"2"` と `"2.0"` は 2 で、`"4.5"` は 0 を返して知らせる (``JSONObject/getInt(_:)``
    /// と同じ)。綴りの決まりは ``getFloatContent()`` と同じ (10 進だけ・前後の空白を落とす)。小数が要る
    /// ときは ``getFloatContent()``。
    ///
    /// **整数にならないときは 0 を返し、初回だけ理由を知らせる** — 文字が無い・端数のある数・`Int` に
    /// 収まらない数・数でない文字のどれでも (要素の名前ごとに 1 度)。読み取りは落ちない
    /// ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getIntContent() -> Int {
        if let number = DecimalText.int(element.content) { return number }
        DocumentValues.warnOnce(
            .contentNotAnInteger(element: element.name),
            "getIntContent(): <\(element.name)> holds \(spokenContent), which is not an integer "
                + "that fits in an Int. Reading it as 0 (said once per element name)")
        return 0
    }

    /// 知らせの中で、要素の文字を名乗る形。
    private var spokenContent: String {
        element.content.isEmpty ? "no text" : "\"\(element.content)\""
    }

    /// 属性を文字として読む。
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// text(star.getString("name"), star.getFloat("x"), star.getFloat("y"))
    /// ```
    ///
    /// 属性の値を書かれたままの文字で返す (実体参照は解いた値)。数として読むのは ``getFloat(_:)``。
    ///
    /// **属性が無ければ空の文字を返し、初回だけ理由を知らせる** (要素の名前と属性の名前の組ごとに
    /// 1 度)。読み取りは落ちない ([ADR-0020] 決定 5)。空の値の属性 (`name=""`) は、あるので知らせない。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getString(_ name: String) -> String {
        if let text = element.attributes[name] { return text }
        DocumentValues.warnOnce(
            .noAttribute(element: element.name, name: name),
            "getString(\"\(name)\"): <\(element.name)> has no attribute \"\(name)\". "
                + DocumentValues.listing("Its attributes are", element.attributes.keys)
                + ". Reading it as an empty string (said once per attribute)")
        return ""
    }

    /// 属性を数として読む。
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// circle(star.getFloat("x"), star.getFloat("y"), star.getFloat("size"))
    /// ```
    ///
    /// 数とするのは **10 進の綴りだけ** (`"120"`・`"-2.5"`・`".5"`・`"1e3"`) で、前後の空白は
    /// 改行 (`&#10;` で書いたもの) も含めて落とす。`Float` に収まらない数 (`"1e39"`) は無限大
    /// になる。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — 属性が無い・値が数でない
    /// 文字のどちらでも (要素の名前と属性の名前の組ごとに 1 度)。`"nan"`・`"NaN"`・`"inf"`・
    /// `"Infinity"`・16 進 (`"0x10"`) も、数でない文字である。読み取りは落ちない
    /// ([ADR-0020] 決定 5)。NaN の大きさの円は描かれないので、欠けた星は抜けとして見える。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getFloat(_ name: String) -> Float {
        guard let text = element.attributes[name] else {
            DocumentValues.warnOnce(
                .noAttribute(element: element.name, name: name),
                "getFloat(\"\(name)\"): <\(element.name)> has no attribute \"\(name)\". "
                    + DocumentValues.listing("Its attributes are", element.attributes.keys))
            return .nan
        }
        if let number = DecimalText.float(text) { return number }
        DocumentValues.warnOnce(
            .attributeNotANumber(element: element.name, name: name),
            "getFloat(\"\(name)\"): <\(element.name)> has \(name)=\"\(text)\", which is not a number. "
                + "Reading it as NaN (said once per attribute)")
        return .nan
    }

    /// 属性を整数として読む。
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// let rays = star.getInt("rays")
    /// for i in 0..<rays {
    ///     circle(star.getFloat("x") + Float(i) * 8, star.getFloat("y"), 4)
    /// }
    /// ```
    ///
    /// **丸めない** — `"2"` と `"2.0"` は 2 で、`"2.5"` は 0 を返して知らせる (``JSONObject/getInt(_:)``
    /// と同じ)。綴りの決まりは ``getFloat(_:)`` と同じ (10 進だけ・前後の空白を落とす)。
    ///
    /// **整数にならないときは 0 を返し、初回だけ理由を知らせる** — 属性が無い・端数のある数・`Int` に
    /// 収まらない数・数でない文字のどれでも (要素の名前と属性の名前の組ごとに 1 度)。読み取りは落ちない
    /// ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getInt(_ name: String) -> Int {
        guard let text = element.attributes[name] else {
            DocumentValues.warnOnce(
                .noAttribute(element: element.name, name: name),
                "getInt(\"\(name)\"): <\(element.name)> has no attribute \"\(name)\". "
                    + DocumentValues.listing("Its attributes are", element.attributes.keys))
            return 0
        }
        if let number = DecimalText.int(text) { return number }
        DocumentValues.warnOnce(
            .attributeNotAnInteger(element: element.name, name: name),
            "getInt(\"\(name)\"): <\(element.name)> has \(name)=\"\(text)\", which is not an integer "
                + "that fits in an Int. Reading it as 0 (said once per attribute)")
        return 0
    }

    /// その名前の属性があるか。値が空の文字 (`name=""`) でも、あれば `true`。
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// if star.hasAttribute("name") {
    ///     text(star.getString("name"), star.getFloat("x"), star.getFloat("y"))
    /// }
    /// ```
    ///
    /// **知らせない** — 属性が無いかもしれないことを分かって尋ねる口である (``JSONObject/hasKey(_:)`` と同じ)。
    public func hasAttribute(_ name: String) -> Bool {
        element.attributes[name] != nil
    }

    /// 属性の名前の一覧。**文字の順に並べる。**
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// for (i, name) in star.listAttributes().enumerated() {
    ///     text("\(name) = \(star.getString(name))", 20, 30 + Float(i) * 20)
    /// }
    /// ```
    ///
    /// XML の属性は順を持たず、読み手 (`XMLParser`) も書かれた順を渡さないので、そのままだと実行ごとに
    /// 並びが変わる。文字の順にそろえてあるので、何度走らせても同じ並びになる (``JSONObject/keys`` と同じ)。
    /// 数は `count` で引く。
    public func listAttributes() -> [String] {
        element.attributes.keys.sorted()
    }
}
