<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

画面の座標と空間の座標を行き来できるようになりました。`screenX(x, y, z)` / `screenY(x, y, z)` / `screenZ(x, y, z)` は、いまの変換といまの視点を通した点が**面のどこに、どれだけ奥に**出るかを返します (奥行きは 0 が手前の面、1 が奥の面)。逆に `spacePosition(screenX:screenY:depth:)` は、指した面の位置が空間のどこを指すかを返します — `depth` にはたいてい掴んだ物の `screenZ` を渡すので、「掴んだ物を画面に沿って引きずる」が数行で書けます。奥行きを渡さない `screenX(x, y)` の意味は変わりません (視点を通さず、変換だけを通す)。あわせて、これらの座標はスケッチが走っていないとき (初期化の中・後片付けの後) に呼んでも落ちなくなり、空の値を返します。
