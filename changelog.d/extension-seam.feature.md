<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

外から機能を足せるようになりました。差込口は **出口** (`Outlet` — フレーム 1 枚を受ける) と **入り口** (`Inlet` — フレームの前に値を供給する) の 2 種類で、`Plugin` に束ねてスケッチの `plugins` へ並べます。並びは 1 本で、順序は宣言順です。

```swift
final class MySketch: Sketch {
    var plugins: [any Plugin] { [VideoSender(name: "mokume")] }
}
```

出口が受け取る `OutputFrame` は**出力段を通した後の絵**で、画像の書き出しと同じものです。GPU のテクスチャのまま受け取れば読み戻しを払いません。

**1 つ転んでもフレームは止まりません。** 開くのに失敗した束はその束だけが外れ、毎フレームの呼び出しで続けて転んだ差込口も外れて、どちらも理由が診断に出ます。
