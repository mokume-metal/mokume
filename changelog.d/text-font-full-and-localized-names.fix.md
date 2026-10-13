<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`textFont()` が、この環境に在る書体を日本語の名前やフルネームで指定しても断らなくなりました。** これまでは `textFont("ヒラギノ角ゴシック W3")`・`textFont("游明朝体")`・`textFont("Hiragino Sans W6")`・`textFont("Helvetica Neue Bold")` のように、書体メニューや Font Book に出る名前を渡すと「無い」と警告して書体を変えませんでした。いまは PostScript 名・ファミリー名に加えて、CoreText が名前として引けるフルネームと、書体が持つ各言語の名前で引けます。濁点を分けて綴った名前も、合わせた綴りと同じに扱います。無い名前は、いままでどおり警告して書体を変えません。

**`textStyle()` の太さ・傾きの面を書体が持たないとき、警告を 1 度出すようにしました。** ヒラギノ角ゴシックや游明朝体、Kefa III を `textStyle(.italic)` にすると、これまでは何も言わずに立体のまま描いていました。描き方は変わらず、そのことを知らせます。
