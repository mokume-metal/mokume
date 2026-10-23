<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**呼んだ時点の絵に効果をその場で掛ける `filter([…])`、絵ごとに掛けて新しい絵を返す `Image.filtered([…])`、2 値化の効果 `Effect.threshold(level:)` を足しました** ([#2455](https://github.com/mokume-metal/mokume/issues/2455))。`filter()` は呼んだ後に描くものには掛からず、掛けた絵は次のフレームへ持ち越します (Processing の `filter()` と同じ。フレームの終わりに掛けて持ち越さない `effects()` とは逆です)。ぼかした場面の上に、くっきりした計器や字を置けます。`Image.filtered(_:)` は元の絵を変えず、毎回確保がかかります。`threshold(level:)` は R・G・B の最大が `level` (0…1) 以上の画素を白、未満を黒にし、アルファは動かしません。

移行: 公開の列挙 `Effect` に場合 `threshold` が増えたので、`Effect` を `switch` で網羅しているコードは、枝が足りないとコンパイル時に指摘されます。`case .threshold(let level):` の枝を足してください。`default:` で受けているコードは変更が要りません。
