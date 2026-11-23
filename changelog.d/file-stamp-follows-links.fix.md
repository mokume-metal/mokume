<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

シンボリックリンクを通して読む画像 (`loadImage`・`requestImage`)・書体 (`loadFont`) と、つまみ・観測・入力のファイルが、リンクの先だけを差し替えたときにも変化に気付くようになった ([#3994](https://github.com/mokume-metal/mokume/issues/3994))。

これまでは更新時刻をリンクそのものから読んでいたので、先だけを書き換えると、走らせたままの差し替えが効かず古い中身のまま残った。いまは中身を読む先 (リンクを辿った先) の時刻で比べる。リンクが切れたときは、ファイルが無いときと同じに扱い、画像は古い控えを返さず読み込みの失敗を返す。
