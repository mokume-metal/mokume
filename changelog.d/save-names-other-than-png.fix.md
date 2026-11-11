<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`save("x.jpg")` のように `.png` で終わらない名前で絵を書くとき、PNG の中身が別の拡張子の名前で黙って並ばなくなった。

- スケッチの `save()` と連番の `beginRecord("out/f-####.jpg")` は、これまでどおり PNG で書いたうえで、書いた形式が PNG であることを 1 度だけ知らせる (`draw()` の中で毎フレーム呼んでも止まらない)
- `Image.save(_:)` は、`.png` (大文字小文字を区別しない) で終わらない名前では書かずに `ImageFailure.unwritable(path:reason:)` を投げる。理由に PNG だけを書くことが載る。**これまで `.jpg` などの名前で書けていた呼び出しは投げるようになる** ので、名前を `.png` に変える

JPEG・TIFF などを選んで書く形は今も無い。
