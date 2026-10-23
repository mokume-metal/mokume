// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// XML の要素 1 つ (`<star x="120" y="80"/>`)。ファイルか URL から読んで根の要素を作り
/// (``SketchPart/loadXML(_:)``)、子の要素を名前で取り出し、属性を読む。
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
}
