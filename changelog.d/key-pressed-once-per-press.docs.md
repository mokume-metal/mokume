<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`keyPressed()` の説明が勧める「押しっぱなしでも 1 回だけ効かせる」書き方を直しました。振る舞いは変わっていません。

これまでの説明は `isKeyDown(_:)` を見るよう勧めていましたが、`keyPressed()` が呼ばれた時点でそのキーは既に押されている扱いなので、**最初の 1 回でも `true` が返り**、連射と見分けられませんでした。代わりに、`keyPressed()` で印を立てて `keyReleased()` で外す形を例つきで載せました。`draw()` を見ない書き方なので、`noLoop()` で止めている間も効きます。

あわせて、押しっぱなしの連射が「Processing / p5.js と同じ」と書いていたのを、「Processing と同じで、p5.js とは違う」に直しました。p5.js は押したままのキーでは `keyPressed()` を呼び直しません ([#1365](https://github.com/mokume-metal/mokume/issues/1365))。
