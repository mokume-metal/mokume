<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`imageMode(.corners)` と `.radius` の下で、3 つの数で置く `image(img, x, y)` (描き場所を置く `image(graphics, x, y)` も) が**絵を等倍で置いていなかった**のを直しました。絵の幅と高さを後の 2 つの数として読んでいたため、`.corners` では置く位置しだいで潰れたり縮んだりし、`.radius` では縦横 2 倍になっていました。いまはどの読み方でも大きさは絵の画素数のままで、(`x`, `y`) は `.corner` / `.corners` なら左上の角、`.center` / `.radius` なら中心に来ます。`.corner` と `.center` の絵、4 つ以上の数で置く形は変わりません ([#1531](https://github.com/mokume-metal/mokume/issues/1531))。
