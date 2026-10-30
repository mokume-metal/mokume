<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume render --scale N` の下で、`createGraphics` の描き場所も倍率を掛けた画素で作られるようになりました ([#3453](https://github.com/mokume-metal/mokume/issues/3453))。これまで描き場所は座標の画素数のまま作られ、`image()` で N 倍に引き伸ばして置かれていたので、面と同じ大きさの描き場所 (残像・フィードバックの定石) を使う作品は、4K・印刷で出しても描き場所の絵だけが甘くなりました。`createGraphics(1920, 1080)` は座標の大きさ (`width` / `height`) が 1920 / 1080 のまま、`--scale 2` では実際の画素 (`pixelWidth` / `pixelHeight`・`pixels`・`get`・`set` の索引) が 3840 / 2160 になります。線の太さ・効果の半径・`clip` の矩形・断片が受ける位置と大きさ・字は、本体の面と同じく倍率を掛けて描かれます。描き場所から作った描き場所も倍率を引き継ぎます。

`image(描き場所, …)` は、置く大きさと切り出しの矩形を描き場所の座標の大きさ (`createGraphics` に渡した幅と高さ) で読むので、`--scale` の有無で構図は変わりません。倍率を書かなければ、また `--scale 1` なら、描き場所の大きさも画素もこれまでと同じです。描き場所のメモリは倍率の 2 乗で増えます。

倍率を掛けた描き場所の一辺が 16384 画素を越えるとき (`--scale 3` で `createGraphics(8192, 100)` など) は、`RenderFailure.sizeBeyondOutputScale(width:height:scale:)` を投げ、文面が倍率と、その倍率で作れる最大の大きさを名乗ります。`RenderFailure` に case が 1 つ増えたので、`switch` で全部の case を列挙している作品は、この case も扱う必要があります。
