// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 色の値の成分の名前 (`premultipliedRed` など) と、保存した値の形が変わらないこと ([#2756])。
///
/// 成分を外から書き換えられないことは、型の面の検査 (`make api-list` で setter が無いこと) が見る。
/// 書き換えが組み上がらないことは、検査では書けない (組めないものは実行できない)。
///
/// [#2756]: https://github.com/mokume-metal/mokume/issues/2756
@Suite("色の値の成分の名前")
struct ColorComponentNamesTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    @Test("成分の名前は、アルファを掛けた線形の値を読み、不透明度は掛けない")
    func namesReadThePremultipliedValues() {
        // 乗算前の (1, 0.5, 0)・不透明度 0.5 は、乗算済みの (0.5, 0.25, 0)・不透明度 0.5 になる
        let half = LinearRGBA(straightRed: 1, green: 0.5, blue: 0, alpha: 0.5)
        #expect(half.premultipliedRed == 0.5)
        #expect(half.premultipliedGreen == 0.25)
        #expect(half.premultipliedBlue == 0)
        #expect(half.alpha == 0.5)
        // 作り方の口が渡した値のままを読める (乗算済みの口は締めない)
        let raw = LinearRGBA(premultipliedRed: 2, green: -1, blue: 0.5, alpha: 1.5)
        #expect(raw.premultipliedRed == 2 && raw.premultipliedGreen == -1)
        #expect(raw.premultipliedBlue == 0.5 && raw.alpha == 1.5)
    }

    /// 完了条件 3: 改名前の形で保存した JSON が読め、保存し直しても値が変わらない。
    @Test("キーが red・green・blue・alpha の JSON を読み、同じキーで書き出す")
    func legacyKeysStillRoundTrip() throws {
        let json = Data(#"{"red":0.5,"green":0,"blue":0.25,"alpha":0.5}"#.utf8)
        let color = try decoder.decode(LinearRGBA.self, from: json)
        #expect(color.premultipliedRed == 0.5)
        #expect(color.premultipliedGreen == 0)
        #expect(color.premultipliedBlue == 0.25)
        #expect(color.alpha == 0.5)
        let written = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(color)) as? [String: Double])
        #expect(written == ["red": 0.5, "green": 0, "blue": 0.25, "alpha": 0.5])
        #expect(try decoder.decode(LinearRGBA.self, from: encoder.encode(color)) == color)
    }

    @Test("値型の fill も、改名前と同じキーで書き、読み直しても変わらない")
    func shapeValuesKeepTheirFillKeys() throws {
        let fill = LinearRGBA(straightRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.5)
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
        #expect(throws: DecodingError.self) { try decoder.decode(LinearRGBA.self, from: renamed) }
        let missing = Data(#"{"red":0.5,"green":0,"alpha":1}"#.utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(LinearRGBA.self, from: missing) }
    }
}
