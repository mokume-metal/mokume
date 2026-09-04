<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`LinearRGBA.opaque(red:green:blue:)` が `LinearRGBA.linear(red:green:blue:)` になった。** 綴りを変えるだけで、振る舞いは同じである。

```swift
ambientLight(.opaque(red: 0.35, green: 0.35, blue: 0.35))   // これまで
ambientLight(.linear(red: 0.35, green: 0.35, blue: 0.35))   // これから
```

`opaque` は「不透明である」ことしか言っておらず、読み手が知りたい**どの目盛りか**を名乗っていなかった。同じ `red` という語で 3 つの目盛りが並ぶ面になったので、口の名前が目盛りを名乗る形に揃えた ([ADR-0033](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md) 決定 2)。

| 口 | `red` の意味 |
| --- | --- |
| `linear(red:green:blue:)` | 線形の 0–1 (**1 を超えてよい** — 光の強さに使う) |
| `display(red:green:blue:)` | エンコード値の 0–1 |
| `color(_:_:_:)` | エンコード値の 0–255 |
