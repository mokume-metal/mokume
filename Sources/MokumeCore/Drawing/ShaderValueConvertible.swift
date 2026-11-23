// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// シェーダへ渡せる値。`Float`・`Int`・`Double` の変数も、`Vector2`・`Vector3`・`LinearRGBA`・`Bool`・
/// `Transform` も、包まずに ``Shader/set(_:_:)-(_,ShaderValueConvertible)`` へ渡せる。
///
/// **Swift の値の型から、シェーダでの型が決まる**:
///
/// | Swift の値 | シェーダの型 |
/// | --- | --- |
/// | `Float`・`Int`・`Double` (変数もリテラルも) | `float` |
/// | ``Vector2`` / ``Vector3`` | `float2` / `float3` |
/// | ``LinearRGBA`` | `float4` (線形・アルファ乗算済み) |
/// | `Bool` | `bool` |
/// | ``Transform`` | `float4x4` |
/// | `.int(n)` と明示したものだけ | `int` |
///
/// 整数の変数もリテラルも `float` で届く。`set("speed", 6)` の宣言が通知なしに `int` に変わらないようにする契約で、
/// 同じ `Int` の変数が `circle()` でも `set()` でも数として扱われる ([ADR-0035])。`int` が要るときだけ
/// ``ShaderValue/int(_:)`` と書く。
///
/// 値の型は、シェーダを作るときの宣言 (`values:`) が決める。後から別の型の値を渡すと、警告して拒否する。
/// `int` で宣言した値は、`set("n", 5)` の `5` が `float` で届くので断られる。**宣言が `.int` なら
/// 書き換えも `.int(n)` と書く。**
/// `SIMD3<Float>` のような SIMD の値は直に受けず、`Vector3(simd)` を通す。
///
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
public protocol ShaderValueConvertible {
    /// シェーダへ渡す形。
    var shaderValue: ShaderValue { get }
}

extension Float: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .number(self) }
}

extension Double: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .number(Float(self)) }
}

extension Int: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .number(Float(self)) }
}

extension Bool: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .bool(self) }
}

extension Vector2: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .pair(x, y) }
}

extension Vector3: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .vector3(self) }
}

extension LinearRGBA: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .color(self) }
}

// 値の型 (`Transform`・`ShaderValue`) の適合は、型に付けた `nonisolated` が効かないのでここにも書く。
// main actor のプロトコルの要件を満たすメンバは、`nonisolated extension` の中でも要件の隔離を継ぐので、
// メンバにも書く。これで値から `shaderValue` を読むのが main の外でも組める。プロトコル自体は main actor の
// まま — 利用者の型の適合を変えないため (#4098)
nonisolated extension Transform: ShaderValueConvertible {
    public nonisolated var shaderValue: ShaderValue { .transform(self) }
}

nonisolated extension ShaderValue: ShaderValueConvertible {
    public nonisolated var shaderValue: ShaderValue { self }
}
