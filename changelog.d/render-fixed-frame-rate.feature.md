<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume render` で、スケッチの動きを決まった速さのまま書き出せるようになりました。** `mokume render --fps 60 --seconds 4 --out motion.mov` のように打つと、窓を開かずに `fps × seconds` 枚を描いて `.mov` (ProRes 4444) か連番 (`out/frame-####.png`) に書き、自分で終わります。書き出しの間、スケッチから見える `time` は 1 枚ごとに `1 / fps` ずつ進むので、重いフレームがあっても動きは歪まず、同じ引数からは同じ動きが出ます。作品のコードは書き換えなくてよく、`beginRecord` を呼ぶ必要もありません。

`fps × seconds` が整数にならない組や、`--fps` / `--seconds` / `--out` の欠けは、ビルドの前に使い方の誤りとして止まります。途中で `Control` + `C` で止めても、それまでの枚が入った開ける動画が残ります。揃わなかったとき (途中で止めた・書き込めなかった・描けないフレームがあった) は 0 以外で終わります。1 枚を描く速さは画面のリフレッシュ (作品が宣言した `frameRate` が上限) のままで、全速では回しません。
