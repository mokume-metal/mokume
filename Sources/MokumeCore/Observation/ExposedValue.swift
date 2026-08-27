// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// スケッチが観測へ差し出した値。
///
/// **型を値の隣に書く。** 値だけを裸で置くと、読み手は 1.0 が実数なのか整数なのかを
/// 推測することになり、JSON の数値表現に依存した読み方が生まれる。
public enum ExposedValue: Encodable, Equatable, Sendable {
    case float(Double)
    case int(Int)
    case string(String)
    case bool(Bool)

    /// 形式の中で名乗る型の名前。
    public var typeName: String {
        switch self {
        case .float: "float"
        case .int: "int"
        case .string: "string"
        case .bool: "bool"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .float(let value): try container.encode(value, forKey: .value)
        case .int(let value): try container.encode(value, forKey: .value)
        case .string(let value): try container.encode(value, forKey: .value)
        case .bool(let value): try container.encode(value, forKey: .value)
        }
    }
}
