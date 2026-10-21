<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

公開の面のベクトルを、`SIMD2<Float>` / `SIMD3<Float>` から自前の `Vector2` / `Vector3` に揃えました ([#2617](https://github.com/mokume-metal/mokume/issues/2617))。`Vector3` はこの版で新しく足しました (`Vector2` は先に入っています)。数は `Float`・`Double`・`Int` のどれでも渡せ (`Vector3(column * 40, 150, 0)`)、`[200, 150, 500]` のような配列リテラルからも作れ、`+`・`-`・数との `*` / `/` ができます。中身は SIMD のままで、SIMD との出入り口は `.simd` と `Vector3(simd)` です。

移した先は次のとおりです。

| 口 | これまで | これから |
| --- | --- | --- |
| `Camera` の `eye`・`center`・`up` と `init(eye:center:up:projection:)` | `SIMD3<Float>` | `Vector3` |
| `Orbit` の `center`・`eye`・`up` と `init(center:…)` | `SIMD3<Float>` | `Vector3` |
| `Placement.rotation` と `init(…rotation:…)` | `SIMD3<Float>` | `Vector3` |
| `Transform.apply(x:y:)` / `apply(x:y:z:)` の戻り値 | `SIMD2<Float>` / `SIMD3<Float>` | `Vector2` / `Vector3` |
| `spacePosition(screenX:screenY:depth:)` の戻り値 | `SIMD3<Float>` | `Vector3` |
| `Model.size`・`Model.center` | `SIMD3<Float>` | `Vector3` |
| `TextContour.points` と `init(points:isHole:)` | `[SIMD2<Float>]` | `[Vector2]` |
| `Gamepad.leftStick`・`GamepadInput.leftStick` | `SIMD2<Float>` | `Vector2` |
| `ParamValue.vector2`・`.vector3` の関連値 | `SIMD2<Float>` / `SIMD3<Float>` | `Vector2` / `Vector3` |
| `@Param` に書ける組 | `SIMD2<Float>` / `SIMD3<Float>` | `Vector2` / `Vector3` |

移行: コンパイルが型の食い違いを指すので、その行の値を `Vector3(…)` / `Vector2(…)` で包むか、読むほうを `.simd` で SIMD に戻してください。`camera.eye = SIMD3(0, 0, 500)` は `camera.eye = Vector3(0, 0, 500)` に、`Placement(rotation: SIMD3(0, angle, 0))` は `Placement(rotation: Vector3(0, angle, 0))` に、`@Param var drift: SIMD2<Float> = SIMD2(0, 0)` は `@Param var drift: Vector2 = Vector2(0, 0)` になります。SIMD の関数に渡すときは `length(model.size.simd)` のように `.simd` を付けます。`@Param` の保存値 (`.mokume/state/params.json`) の形は変わらず、これまでに保存した組の値は、そのまま `Vector2` / `Vector3` の `@Param` に読み戻されます。
