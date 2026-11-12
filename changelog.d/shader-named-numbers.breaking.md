<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**シェーダが数の並びを名前で何本も読めるようになりました。** `loadShader`・`createShader` に `numbers:` で名前を付けた並びを渡すと、シェーダの入口が `Numbers numbers` を受け取り、`numbers.<名前>[i]` で読めます。面の `surfaces:` と同じ形で、渡せるのは 4 本まで、並びは `shader.set("名前", 並び)` で差し替えます。面と並びの両方を渡したシェーダは `paint(Fragment in, Values values, Surfaces surfaces, Numbers numbers)` と受け取ります。これまでの `numbers(_:)`・`resetNumbers()`・`in.numbers` はそのまま使えます。

```swift
let shader = try createShader(
    """
    float4 paint(Fragment in, Values values, Numbers numbers) {
        uint i = uint(in.place.x * 16.0);
        return float4(numbers.field[i], numbers.profile[i], 0.0, 1.0);
    }
    """,
    numbers: ["field": field, "profile": profile])
```

**公開の `ShaderFailure` を広げたので、破壊的な変更である。** 渡した並びが 4 本を超えたときに投げる場合 `tooManyNumbers(path:count:capacity:)` を足した。**移行**: `ShaderFailure` を網羅して `switch` していたなら、`.tooManyNumbers` の場合を足す (`.tooManySurfaces` と同じ扱いでよい)。
