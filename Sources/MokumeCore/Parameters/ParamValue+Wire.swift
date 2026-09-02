// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 面に出る値の書き方と読み方。
///
/// 名乗り方は観測が差し出す値と同じ `{"type", "value"}` で、**同じ意味の表現を
/// 2 つ作らない** ([ADR-0030] 決定 4)。形の正典は `Schemas/params-report.schema.json` と
/// `Schemas/params-request.schema.json`。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
extension ParamValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    /// 色の成分。作業空間の表現をそのまま出すので、往復に変換が挟まらない
    /// ([ADR-0011](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md) 決定 4 の乗算済みの値)。
    private struct WireColor: Codable {
        let red: Float
        let green: Float
        let blue: Float
        let alpha: Float
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        try container.encode(Body(self), forKey: .value)
    }

    /// 値の中身だけ (型の名乗りを持たない形)。
    ///
    /// 型の名乗りを隣に置く面 (要求と応答の値) と、宣言の中に畳む面 (応答の宣言) の
    /// **どちらも同じ書き方になる**ようにここへ寄せる。2 か所で書き分けると、
    /// いつか片方だけが変わる。
    struct Body: Encodable {
        let value: ParamValue

        init(_ value: ParamValue) {
            self.value = value
        }

        func encode(to encoder: any Encoder) throws {
            switch value {
            case .float(let number):
                var container = encoder.singleValueContainer()
                try container.encode(number)
            case .int(let number):
                var container = encoder.singleValueContainer()
                try container.encode(number)
            case .bool(let flag):
                var container = encoder.singleValueContainer()
                try container.encode(flag)
            case .string(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .color(let color):
                var container = encoder.singleValueContainer()
                try container.encode(
                    WireColor(
                        red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
            case .vector2(let vector):
                var container = encoder.singleValueContainer()
                try container.encode([vector.x, vector.y])
            case .vector3(let vector):
                var container = encoder.singleValueContainer()
                try container.encode([vector.x, vector.y, vector.z])
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "float": self = .float(try container.decode(Double.self, forKey: .value))
        case "int": self = .int(try container.decode(Int.self, forKey: .value))
        case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "string": self = .string(try container.decode(String.self, forKey: .value))
        case "color":
            let color = try container.decode(WireColor.self, forKey: .value)
            self = .color(
                LinearRGBA(
                    premultipliedRed: color.red, green: color.green, blue: color.blue,
                    alpha: color.alpha))
        case "vec2":
            let components = try container.decode([Float].self, forKey: .value)
            guard components.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "vec2 は 2 つの成分で書く")
            }
            self = .vector2(SIMD2(components[0], components[1]))
        case "vec3":
            let components = try container.decode([Float].self, forKey: .value)
            guard components.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "vec3 は 3 つの成分で書く")
            }
            self = .vector3(SIMD3(components[0], components[1], components[2]))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "知らない型: \(type)")
        }
    }
}

extension ParamDeclaration: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, type, value, min, max, choices
    }

    /// 宣言 1 つぶん。**値と一緒に、動ける幅と許した候補も出す** — 読み手が別の面を
    /// 見に行かなくて済むようにするため ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 2)。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(typeName, forKey: .type)
        // 値は型の名乗りを持たない (この宣言の type がそれを言っている)
        try container.encode(ParamValue.Body(value), forKey: .value)
        if let range {
            try container.encode(range.lowerBound, forKey: .min)
            try container.encode(range.upperBound, forKey: .max)
        }
        if let choices {
            try container.encode(choices, forKey: .choices)
        }
    }

    /// 宣言 1 つぶんを読む。
    ///
    /// **読む側が要るのは道具である** — 見張りが出すプレビューはスケッチを持っていないので、
    /// つまみに並べる宣言をこの面から引く ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 5)。
    ///
    /// 型と値は**書いた側と同じ組**として読む — 宣言は `type` と `value` を隣に持つので、
    /// 値の読み方 (``ParamValue/init(from:)``) をそのまま当てられる。書き方だけを 2 度
    /// 書かないのと同じ理由で、読み方も 1 つにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let value = try ParamValue(from: decoder)
        let lower = try container.decodeIfPresent(Double.self, forKey: .min)
        let upper = try container.decodeIfPresent(Double.self, forKey: .max)
        // **片側だけの幅は幅ではない。** 書く側は両方揃えて出すので、揃っていなければ
        // 幅が無いものとして扱う (誤った端で動きを縛るより、縛らないほうが害が小さい)
        var range: ParamRange?
        if let lower, let upper, lower <= upper { range = ParamRange(lower...upper) }
        self.init(
            name: name, value: value, range: range,
            choices: try container.decodeIfPresent([String].self, forKey: .choices))
    }
}
