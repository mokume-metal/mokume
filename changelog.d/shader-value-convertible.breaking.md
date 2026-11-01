<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

塗り・効果・計算の `set(_:_:)` が、Swift の値を包まずに受けるようになりました ([#3568](https://github.com/mokume-metal/mokume/issues/3568))。`Float`・`Int`・`Double` の変数、`Vector2`・`Vector3`・`LinearRGBA`・`Bool`・`Transform` をそのまま渡せます。`stir.set("time", .number(time))` は `stir.set("time", time)` と書けます。受け口の型は新しい `ShaderValueConvertible` で、`ShaderValue` を受ける既存の口も残っています。

断片での型は、Swift の値の型から決まります。

| Swift の値 | 断片の型 |
| --- | --- |
| `Float`・`Int`・`Double` (変数もリテラルも) | `float` |
| `Vector2` / `Vector3` | `float2` / `float3` |
| `LinearRGBA` | `float4` (線形・アルファ乗算済み) |
| `Bool` | `bool` |
| `Transform` | `float4x4` |
| `.int(n)` と明示したものだけ | `int` |

整数は変数もリテラルも `float` のままなので、`set("speed", 6)` の宣言は今までと同じ `float speed;` です。

この型の割り当てのために、公開の `ShaderValue` に case を 4 つ足しました: `.vector3(Vector3)`・`.bool(Bool)`・`.int(Int)`・`.transform(Transform)`。`Vector2` は既存の `.pair` で渡します。値の詰め方は Metal の構造体の配置に合わせて、`float3` は 16 バイト、`float4x4` は 64 バイト、`bool` は 1 バイトで詰めます。上限を超えたときの案内も、足した型の数え方 (`float3` は 4、`float4x4` は 16) に直しました。

移行: `ShaderValue` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`.vector3`・`.bool`・`.int`・`.transform` の枝を足すか、`default` で受けてください。`ShaderValue` を作って `set` や `values:` に渡しているだけのコードは、変更不要です。
