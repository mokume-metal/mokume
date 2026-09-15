<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

数で書いた色 (`fill(204, 153, 0)`・`color(...)`・`LinearRGBA.display(...)`・光の色) を、**sRGB の原色の値**として作業空間へ移すようになりました。これまでは Display P3 の原色の値として扱っていたため、同じ数でも sRGB の画像を `loadImage` した色より彩度が高く出て、Processing / p5 とも色が違っていました。いまは同じ数から、手本と同じ色・読み込んだ sRGB の画像と同じ色が出ます。

**彩度のある色で描いていた既存のスケッチは、見た目が変わります** (色味が手本の色見本どおりに落ち着きます)。灰色 (赤・緑・青が等しい色) は変わりません。書き出した PNG は作業空間の Display P3 を刻むので、彩度のある色のバイト列は打った数と一致しなくなります (`204, 153, 0` は `196, 155, 51` として書かれます)。`red()` / `green()` / `blue()` と色相・彩度・明度の読み出しは同じ変換を逆にたどるので、`red(color(255, 204, 0))` はこれまでどおり 255 を返します。

移行: 新しい色で問題なければ何もしなくて構いません。これまでの見た目を保つための「P3 の値を数で受ける口」は用意していません ([ADR-0011](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md) 決定 3)。sRGB の外の色は、作業空間の線形値を受ける `LinearRGBA.linear(red:green:blue:)` で書けます。数をこの口へそのまま移すことはできず、線形の光の量として書き直す必要があります。
