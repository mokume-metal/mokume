// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 色の値の成分の名前 (`premultipliedRed` など) と、保存した値の形が変わらないこと ([#2756])。
///
/// 成分を外から書き換えられないことは、`WritableKeyPath` にならないことで見る (組めないものは実行できない
/// ので、書き換えの文そのものは書けない)。`public var` に戻すと、この検査が赤くなる。
///
/// [#2756]: https://github.com/mokume-metal/mokume/issues/2756
@Suite("色の値の成分の名前")
struct ColorComponentNamesTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// 完了条件 1: 4 成分とも、外から書き換えられない。
    ///
    /// 書き換えの文は組めないので、キーパスの**組み上がる型**で見る — 書き換えられる成分は
    /// `WritableKeyPath` として組まれ、読むだけの成分は `KeyPath` にしか組まれない。実行時の型は
    /// どちらも書き換え可能な入れ物なので、組む時に決まる多重定義の選びで見分ける。
    @Test("成分と不透明度は読むだけで、書き換えの口を持たない")
    func componentsAreReadOnly() {
        #expect(!Self.isWritable(\Color.premultipliedRed))
        #expect(!Self.isWritable(\Color.premultipliedGreen))
        #expect(!Self.isWritable(\Color.premultipliedBlue))
        #expect(!Self.isWritable(\Color.alpha))
    }

    private static func isWritable<Root, Value>(_ path: WritableKeyPath<Root, Value>) -> Bool { true }
    private static func isWritable<Root, Value>(_ path: KeyPath<Root, Value>) -> Bool { false }

    /// 移行の対応表 (`changelog.d/color-components-read-only.breaking.md`) の、不透明度を変える 2 通り。
    /// **掛ける**口と**置き換える**書き方は、半透明の色では別の値になる。
    @Test("不透明度を変える 2 通り: 掛けるのは color(c, a)・置き換えるのは読み直して作り直す")
    func changingTheOpacityMultipliesOrReplaces() {
        let opaque = color(255, 255, 255)
        let half = color(255, 255, 255, 128)
        // 不透明な色は、どちらも同じ (0.3 × 255 の不透明度)
        for result in [
            color(opaque, 0.3 * 255),
            color(red(opaque), green(opaque), blue(opaque), 0.3 * 255),
        ] {
            #expect(abs(alpha(result) - 0.3 * 255) < 0.1, "\(alpha(result))")
        }
        // 半透明の色では、掛けると 128 × 0.3 になり、置き換えると 0.3 × 255 になる
        let multiplied = color(half, 0.3 * 255)
        let replaced = color(red(half), green(half), blue(half), 0.3 * 255)
        #expect(abs(alpha(multiplied) - 128 * 0.3) < 0.1, "\(alpha(multiplied))")
        #expect(abs(alpha(replaced) - 0.3 * 255) < 0.1, "\(alpha(replaced))")
        // 置き換えても、色みは動かない (乗算していない値は同じ)
        #expect(abs(red(replaced) - 255) < 0.5 && abs(green(replaced) - 255) < 0.5)
    }

    @Test("成分の名前は、アルファを掛けた線形の値を読み、不透明度は掛けない")
    func namesReadThePremultipliedValues() {
        // 乗算前の (1, 0.5, 0)・不透明度 0.5 は、乗算済みの (0.5, 0.25, 0)・不透明度 0.5 になる
        let half = Color(straightRed: 1, green: 0.5, blue: 0, alpha: 0.5)
        #expect(half.premultipliedRed == 0.5)
        #expect(half.premultipliedGreen == 0.25)
        #expect(half.premultipliedBlue == 0)
        #expect(half.alpha == 0.5)
        // 作り方の口が渡した値のままを読める (乗算済みの口は締めない)
        let raw = Color(premultipliedRed: 2, green: -1, blue: 0.5, alpha: 1.5)
        #expect(raw.premultipliedRed == 2 && raw.premultipliedGreen == -1)
        #expect(raw.premultipliedBlue == 0.5 && raw.alpha == 1.5)
    }

    /// 完了条件 3: 改名前の形で保存した JSON が読め、保存し直しても値が変わらない。
    @Test("キーが red・green・blue・alpha の JSON を読み、同じキーで書き出す")
    func legacyKeysStillRoundTrip() throws {
        let json = Data(#"{"red":0.5,"green":0,"blue":0.25,"alpha":0.5}"#.utf8)
        let color = try decoder.decode(Color.self, from: json)
        #expect(color.premultipliedRed == 0.5)
        #expect(color.premultipliedGreen == 0)
        #expect(color.premultipliedBlue == 0.25)
        #expect(color.alpha == 0.5)
        let written = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(color)) as? [String: Double])
        #expect(written == ["red": 0.5, "green": 0, "blue": 0.25, "alpha": 0.5])
        #expect(try decoder.decode(Color.self, from: encoder.encode(color)) == color)
    }

    @Test("値型の fill も、改名前と同じキーで書き、読み直しても変わらない")
    func shapeValuesKeepTheirFillKeys() throws {
        let fill = Color(straightRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.5)
        let circle = Circle(x: 1.5, y: -2, radius: 3, fill: fill)
        let written = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(circle)) as? [String: Any])
        let keys = try #require(written["fill"] as? [String: Double]).keys.sorted()
        #expect(keys == ["alpha", "blue", "green", "red"])
        #expect(try decoder.decode(Circle.self, from: encoder.encode(circle)) == circle)
        let rect = Rect(left: 4, top: 5, width: 6, height: 7, fill: fill)
        #expect(try decoder.decode(Rect.self, from: encoder.encode(rect)) == rect)
    }

    /// 失敗系: 新しい名前のキーは受けない (保存した形は `red` のまま)。キーが欠けていれば読めない。
    @Test("新しい名前をキーにした JSON と、キーが欠けた JSON は読めない")
    func newNamesAreNotKeys() {
        let renamed = Data(
            #"{"premultipliedRed":0.5,"premultipliedGreen":0,"premultipliedBlue":0,"alpha":1}"#.utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(Color.self, from: renamed) }
        let missing = Data(#"{"red":0.5,"green":0,"alpha":1}"#.utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(Color.self, from: missing) }
    }
}
