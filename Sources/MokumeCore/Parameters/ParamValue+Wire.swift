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
    private struct WireColor: Encodable {
        let red: Float
        let green: Float
        let blue: Float
        let alpha: Float
    }

    /// 色の成分を**読むとき**の形。`Float` ではなく `Double` で読む。
    ///
    /// `Float` で読むと、`Float` に収まらない数 (`1e300`) で `JSONDecoder` が**文書ごと**断り、
    /// 要求が応答も警告もなしに捨てられる (同じ要求の他の値も入らない)。`Double` で読んで
    /// `Float` へ読み替えれば、桁あふれは無限になり、置き場がその値だけを拒む
    /// (``ParamOutcome/notFinite``・[#2271](https://github.com/mokume-metal/mokume/issues/2271))。
    /// `Double` にも収まらない数 (`1e400`) は `JSONDecoder` が数そのものを読めずここで断るが、
    /// 要求の 1 件ずつの読み (``ParamRequest/Entry``) が受けて、その 1 件だけを
    /// ``ParamOutcome/notFinite`` と同じ理由で拒む ([#2496](https://github.com/mokume-metal/mokume/issues/2496))。
    private struct WideWireColor: Decodable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
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
        let name = try container.decode(String.self, forKey: .type)
        // 綴りは書く側と同じ正典から引く。知らない綴りを落とすのは `init(rawValue:)` の
        // 仕事で、そこから先は `default` を持たない — 書けるのに読めない型を作らせない
        guard let type = ParamTypeName(rawValue: name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown type: \(name)")
        }
        switch type {
        case .float: self = .float(try container.decode(Double.self, forKey: .value))
        case .int: self = .int(try container.decode(Int.self, forKey: .value))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .color:
            let color = try container.decode(WideWireColor.self, forKey: .value)
            self = .color(
                LinearRGBA(
                    premultipliedRed: Float(color.red), green: Float(color.green),
                    blue: Float(color.blue), alpha: Float(color.alpha)))
        case .vec2:
            let components = try container.decode([Double].self, forKey: .value)
            guard components.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "vec2 is written with 2 components")
            }
            self = .vector2(SIMD2(Float(components[0]), Float(components[1])))
        case .vec3:
            let components = try container.decode([Double].self, forKey: .value)
            guard components.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "vec3 is written with 3 components")
            }
            self = .vector3(SIMD3(Float(components[0]), Float(components[1]), Float(components[2])))
        }
    }
}

extension ParamDeclaration: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, type, value, min, max, choices, step
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
            if case .int = value, let bounds = range.integerBounds {
                // **整数の宣言の端は整数のまま出す。** `Double` で出すと `Int.max` は 2^63 になり、
                // 読み手が端を `int` の値として書き戻すと `Int` に収まらない数になる (#2478)
                try container.encode(bounds.lowerBound, forKey: .min)
                try container.encode(bounds.upperBound, forKey: .max)
            } else {
                try container.encode(range.lowerBound, forKey: .min)
                try container.encode(range.upperBound, forKey: .max)
            }
        }
        if let choices {
            try container.encode(choices, forKey: .choices)
        }
        if let step {
            try container.encode(step, forKey: .step)
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
        // **刻みも書く側の検めを通った値だけが来る** (``ParamStep``) が、読む側は書き手を信じ切らない:
        // 0 以下・非有限の刻みはスライダーを組めないので、無いものとして読む
        let step = try container.decodeIfPresent(Double.self, forKey: .step)
            .flatMap { ParamStep.check($0, for: value).step }
        self.init(
            name: name, value: value, range: range,
            choices: try container.decodeIfPresent([String].self, forKey: .choices), step: step)
    }
}
