<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**呼んだ時点の絵に効果をその場で掛ける `filter([…])`、絵ごとに掛けて新しい絵を返す `Image.filtered([…])`、2 値化の効果 `Effect.threshold(level:)` を足しました** ([#2455](https://github.com/mokume-metal/mokume/issues/2455))。`filter()` は呼んだ後に描くものには掛からず、掛けた絵は次のフレームへ持ち越します (Processing の `filter()` と同じ。フレームの終わりに掛けて持ち越さない `effects()` とは逆です)。ぼかした場面の上に、くっきりした計器や字を置けます。**掛けた絵は残るので、`filter()` は図形・絵・背景と同じ「置いたもの」の寿命です** — `draw()` の中のほか、`setup()` と止まっている間のコールバックでも掛けられ、`setup() { image(photo, 0, 0); filter([.blur(radius: 6)]); noLoop() }` と書けます (止まっている間は、次のフレームの入りになる効果を通す前の絵にも掛かります)。区間の外と形の組み立ての中では、`effects()` とは別の注意を 1 度だけ出して何もしません。`Image.filtered(_:)` は元の絵を変えず、作業の面は絵が持って使い回しますが、効果を通して読み戻す費用と新しい絵の確保は毎回かかります。`threshold(level:)` は R・G・B の最大が `level` (0…1) 以上の画素を白、未満を黒にし、アルファは動かしません。不透明度 0 で色を持つ画素 (透明な地へ加算した光) も白か黒になり、`fill(128)` に `level: 128 / 255` のようなちょうどの値は白になります。

移行: 公開の列挙 `Effect` に場合 `threshold` が増えたので、`Effect` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .threshold(let level):` の枝を足してください。`default:` で受けているコードは変更が要りません。
