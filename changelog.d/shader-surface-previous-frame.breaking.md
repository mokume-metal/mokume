<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**公開の列挙型 `ShaderSurface` に `.previousFrame` の場合が増えた。** 網羅した `switch` で `ShaderSurface` を分けているコードは、コンパイルが止まる。

**移行**: `switch` に `case .previousFrame:` を足す。`ShaderSurface` を値として渡すだけのコード (`surfaces: ["pattern": .image(checks)]` など) は変わらない。

```swift
switch surface {
case .image(let image): …
case .graphics(let canvas): …
case .previousFrame: …   // 足す
}
```
