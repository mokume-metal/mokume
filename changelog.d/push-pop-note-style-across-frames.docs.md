<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`push()` と `pop()` の説明の Note を、変換だけでなくスタイルの履歴もフレームを越えないと書き直した。積んだ事実は `draw()` の頭で捨てられるので同じフレームの中で釣り合わせること、塗りや混ぜ方そのものはフレームを越えるので、`push(); blendMode(.add)` のまま `pop()` を忘れると次のフレームの頭から加算が効き続けることを書いている。振る舞いは変わらない。
