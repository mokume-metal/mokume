// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// スケッチが観測へ差し出した値。
///
/// **型を値の隣に書く。** 値だけを裸で置くと、読み手は 1.0 が実数なのか整数なのかを
/// 推測することになり、JSON の数値表現に依存した読み方が生まれる。
///
/// ## つまみの値と同じ名乗り方をする
///
/// 綴りも `{"type", "value"}` の形も ``ParamValue`` と分け合う ([ADR-0030] 決定 4 —
/// 同じ意味の表現を 2 つ作らない)。**型を分けたまま**にしているのは、観測が差し出せる
/// のがこの 4 つだけだと言うためで、それは `Schemas/observe-report.schema.json` の
/// `enum` が言っていることと同じである。色や組が要ると分かった日はここへ足し、
/// 同時にあちらの `enum` へも足す — **一致は `scripts/tests/wire_vocabulary_test.py`
/// が見る**。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
public enum ExposedValue: Encodable, Equatable, Sendable {
    case float(Double)
    case int(Int)
    case string(String)
    case bool(Bool)

    /// 形式の中で名乗る型の名前。
    public var typeName: String { paramType.rawValue }

    /// 名乗る型。綴りの正典は ``ParamValue`` と同じ ``ParamTypeName``。
    var paramType: ParamTypeName {
        switch self {
        case .float: .float
        case .int: .int
        case .string: .string
        case .bool: .bool
        }
    }

    /// つまみの面と同じ値の表現。**観測が出せるのは真部分集合**なので、こちらへは
    /// 必ず移せる (逆は移せない)。
    var paramValue: ParamValue {
        switch self {
        case .float(let value): .float(value)
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        }
    }

    /// **書き方は ``ParamValue`` のものをそのまま使う。** 手で書き分けると、いつか
    /// 片方だけが動く。
    public func encode(to encoder: any Encoder) throws {
        try paramValue.encode(to: encoder)
    }
}
