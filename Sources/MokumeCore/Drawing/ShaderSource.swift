// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 断片を、そのままコンパイルできる 1 本の原稿へ組み立てる。
///
/// ## 前置きは無条件に足す
///
/// 「断片が既に宣言を持っていれば足さない」という条件分岐は作らない。**コメントに
/// 書かれた宣言にまで反応して絵が消える**からで、二重に足されても壊れない形にする
/// ほうが安全である。
///
/// ## 並び
///
/// 値の宣言 → 共通部分 → 断片。共通部分が値の型を使い、断片が共通部分の型を使うので、
/// この順序でしか組み立てられない。
enum ShaderSource {
    /// 値の名前と、その形。
    ///
    /// 名前は**断片の中でそのまま書ける識別子**になる。並べる順は名前順に固定する
    /// (辞書の順序に依らせると、同じ断片が実行のたびに別の原稿になる)。
    static func declaration(of values: [String: ShaderValue]) -> String {
        // 4 成分のものを先に並べる。16 バイト境界に揃うものを先に置けば、
        // 詰め物の入り方が Swift 側の並べ方と一致する
        let sorted = values.sorted { ($0.value.componentCount, $0.key) > ($1.value.componentCount, $1.key) }
        let fields = sorted.map { "    \($0.value.metalType) \($0.key);" }
        // 空の構造体は大きさが処理系任せになるので、必ず 1 つは入れておく
        let body = fields.isEmpty ? "    float4 mokume_unused;" : fields.joined(separator: "\n")
        return "struct Values {\n\(body)\n};\n"
    }

    /// 値を、宣言した並びのとおりに詰める。
    static func pack(_ values: [String: ShaderValue]) -> [Float] {
        let sorted = values.sorted { ($0.value.componentCount, $0.key) > ($1.value.componentCount, $1.key) }
        guard !sorted.isEmpty else { return [0, 0, 0, 0] }
        var packed: [Float] = []
        for (_, value) in sorted { packed.append(contentsOf: value.components) }
        // 構造体の大きさは 16 バイト境界へ切り上がる
        while packed.count % 4 != 0 { packed.append(0) }
        return packed
    }

    /// 原稿を組み立てる。
    static func assemble(common: String, values: [String: ShaderValue], body: String) -> String {
        declaration(of: values) + common + "\n" + body + "\n"
    }
}

/// 断片へ渡せる値。
public enum ShaderValue: Equatable, Sendable {
    /// 1 つの数。断片からは `float` として見える。
    case number(Float)
    /// 2 つ組。断片からは `float2` として見える。
    case pair(Float, Float)
    /// 色。断片からは `float4` として見える (線形・アルファ乗算済み)。
    case color(LinearRGBA)

    var metalType: String {
        switch self {
        case .number: "float"
        case .pair: "float2"
        case .color: "float4"
        }
    }

    var componentCount: Int {
        switch self {
        case .number: 1
        case .pair: 2
        case .color: 4
        }
    }

    var components: [Float] {
        switch self {
        case .number(let value): [value]
        case .pair(let x, let y): [x, y]
        case .color(let color): [color.red, color.green, color.blue, color.alpha]
        }
    }
}

extension ShaderValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(Float(value)) }
}

extension ShaderValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Float(value)) }
}
