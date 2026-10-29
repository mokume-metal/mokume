<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`Movie` に、流す速さを変える `speed(_:)` を足しました ([#2451](https://github.com/mokume-metal/mokume/issues/2451))。`clip.speed(2)` で倍速、`clip.speed(0.5)` で半分、`clip.speed(0)` で位置が進まなくなります。流している途中で変えても位置は跳ばず (変えた時点の位置から新しい速さで進みます)、毎フレーム呼んでもよいので、マウスの横の位置で速さを変える、といった使い方が 1 行で書けます。位置は引き続きスケッチの時刻から決まるので、固定の時計で書き出すと、同じフレームには同じコマが出ます。0 以上の有限の値だけを受け、負 (逆再生)・`.nan`・無限は速さを変えず、1 度だけ知らせます。

```swift
clip.speed(map(mouseX, 0, width, 0.25, 4))   // マウスの横の位置で 0.25 倍から 4 倍
```
