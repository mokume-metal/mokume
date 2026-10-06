// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// XML の要素 1 つ (`<star x="120" y="80"/>`)。ファイルか URL から読んで根の要素を作り
/// (``Sketch/loadXML(_:)``)、子の要素を名前で取り出し、属性を読む。
///
/// <!-- example: 文脈 var sky: XML? -->
/// ```swift
/// func setup() {
///     // <sky><star x="120" y="80" size="6"/> … </sky>
///     sky = try? loadXML("data/constellation.xml")
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
/// ## 値の型である
///
/// 代入すると写しになる (``Table`` と同じ)。読むだけで、書き換える口は持たない。
///
/// ## 値が無くても落ちない
///
/// 無い属性や数でない属性を ``getFloat(_:)`` で読むと NaN を返し、**初回だけ理由を知らせる**
/// ([ADR-0020] 決定 5)。
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

    /// 属性を数として読む。
    ///
    /// <!-- example: 文脈 var star: XML! -->
    /// ```swift
    /// circle(star.getFloat("x"), star.getFloat("y"), star.getFloat("size"))
    /// ```
    ///
    /// 前後の空白は落とす。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — 属性が無い・値が数でない
    /// 文字のどちらでも (要素の名前と属性の名前の組ごとに 1 度)。読み取りは落ちない
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
        if let number = Float(text.trimmingCharacters(in: .whitespaces)) { return number }
        DocumentValues.warnOnce(
            .attributeNotANumber(element: element.name, name: name),
            "getFloat(\"\(name)\"): <\(element.name)> has \(name)=\"\(text)\", which is not a number. "
                + "Reading it as NaN (said once per attribute)")
        return .nan
    }
}
