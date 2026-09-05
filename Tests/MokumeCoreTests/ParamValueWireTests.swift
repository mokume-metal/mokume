// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 面に出る値の綴りと形。
///
/// **書いたものを自分で読めるかを見る。** 綴りが書く側と読む側で割れても
/// コンパイルは通り、症状は「置いた値が入らない」としか出ない
/// ([#803](https://github.com/mokume-metal/mokume/issues/803))。
///
/// 型を足した人がここで止まるように、代表値は `default` の無い網羅 `switch` から作る。
@Suite("面に出る値の綴りと形")
struct ParamValueWireTests {
    /// 型 1 つぶんの代表値。**足すとコンパイルが止まる。**
    private func sample(of type: ParamTypeName) -> ParamValue {
        switch type {
        case .float: .float(1.5)
        case .int: .int(-7)
        case .bool: .bool(true)
        case .string: .string("あ\"い")
        case .color: .color(LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        case .vec2: .vector2(SIMD2(1.5, -2.5))
        case .vec3: .vector3(SIMD3(1.5, -2.5, 3.5))
        }
    }

    private func encoded(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test("どの型も、書いて読み戻すと同じ値になる", arguments: ParamTypeName.allCases)
    func survivesTheRoundTrip(type: ParamTypeName) throws {
        let value = sample(of: type)
        #expect(value.paramType == type, "代表値がその型のものになっている")

        let data = try JSONEncoder().encode(value)
        #expect(try encoded(value)["type"] as? String == type.rawValue, "型は綴りのまま名乗る")
        #expect(try JSONDecoder().decode(ParamValue.self, from: data) == value)
    }

    /// 3 つの入口 (外からの要求・道具の要求・保存) が同じ 1 つの形を使う。
    /// かつては 3 か所が別々に書いており、片方だけが動いても誰も言わなかった。
    @Test("名前付きの 1 件も、どの型で往復しても同じ値になる", arguments: ParamTypeName.allCases)
    func namedValuesSurviveTheRoundTrip(type: ParamTypeName) throws {
        let entry = NamedParamValue(name: "knob", value: sample(of: type))
        let object = try encoded(entry)
        #expect(object["name"] as? String == "knob")
        #expect(object["type"] as? String == type.rawValue)

        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(NamedParamValue.self, from: data) == entry)
    }

    /// 観測が差し出す値は、つまみの値の**真部分集合**である。綴りも形も分け合う。
    @Test(
        "観測の値は、つまみの値と同じ綴りと形で出る",
        arguments: [
            ExposedValue.float(1.5), .int(-7), .string("あ"), .bool(true),
        ])
    func exposedValuesSpeakTheSameWire(exposed: ExposedValue) throws {
        let object = try encoded(exposed)
        #expect(object["type"] as? String == exposed.typeName)
        #expect(try encoded(exposed.paramValue) as NSDictionary == object as NSDictionary)
    }

    /// 知らない綴りは読めない。**面が知らない型を黙って通すと、後で値の意味が割れる。**
    @Test("知らない型の綴りは読めない")
    func rejectsUnknownTypeNames() {
        let line = Data(#"{"type":"vector2","value":[1,2]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ParamValue.self, from: line)
        }
    }
}
