// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 断片へ渡せる値。`Float`・`Int`・`Double` の変数も、`Vector2`・`Vector3`・`LinearRGBA`・`Bool`・
/// `Transform` も、包まずに ``Shader/set(_:_:)-(_,ShaderValueConvertible)`` へ渡せる。
///
/// **Swift の値の型から、断片での型が決まる**:
///
/// | Swift の値 | 断片の型 |
/// | --- | --- |
/// | `Float`・`Int`・`Double` (変数もリテラルも) | `float` |
/// | ``Vector2`` / ``Vector3`` | `float2` / `float3` |
/// | ``LinearRGBA`` | `float4` (線形・アルファ乗算済み) |
/// | `Bool` | `bool` |
/// | ``Transform`` | `float4x4` |
/// | `.int(n)` と明示したものだけ | `int` |
///
/// 整数の変数もリテラルも `float` で届く。`set("speed", 6)` の宣言が黙って `int` に変わらないための約束で、
/// 同じ `Int` の変数が `circle()` でも `set()` でも数として扱われる ([ADR-0035])。`int` が要るときだけ
/// ``ShaderValue/int(_:)`` と書く。
///
/// 値の型は、断片を作るときの宣言 (`values:`) が決める。後から別の型の値を渡すと、警告して断る。
/// `SIMD3<Float>` のような SIMD の値は直に受けず、`Vector3(simd)` を通す。
///
/// [ADR-0035]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0035-numeric-reception.md
public protocol ShaderValueConvertible {
    /// 断片へ渡す形。
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

extension Transform: ShaderValueConvertible {
    public var shaderValue: ShaderValue { .transform(self) }
}

extension ShaderValue: ShaderValueConvertible {
    public var shaderValue: ShaderValue { self }
}
