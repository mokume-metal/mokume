<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`createShape` の中で絵を貼った形 (`texture(img)` や、断片の面に渡した `.image(img)`) を作った後で、その絵を `set` / `write` / `fill` で書き換えても、形を `shape()` で置き直すだけのフレームには書き換えた画素が出ていなかったのを直しました。同じフレームで `image(img, …)` を描くと出るため、気付きにくい形でした。保持した形を置き直すときも、記録した絵の書き換えを面へ送るようにしました。書き換えていない絵は、これまでどおり送り直しません。
