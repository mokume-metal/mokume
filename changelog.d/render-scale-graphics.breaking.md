<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume render --scale N` の下で、`createGraphics` の描き場所も倍率を掛けた画素で作られるようになりました ([#3453](https://github.com/mokume-metal/mokume/issues/3453))。これまで描き場所は座標の画素数のまま作られ、`image()` で N 倍に引き伸ばして置かれていたので、面と同じ大きさの描き場所 (残像・フィードバックの定石) を使う作品は、4K・印刷で出しても描き場所の絵だけが甘くなりました。`createGraphics(1920, 1080)` は座標の大きさ (`width` / `height`) が 1920 / 1080 のまま、`--scale 2` では実際の画素 (`pixelWidth` / `pixelHeight`・`pixels`・`get`・`set` の索引) が 3840 / 2160 になります。線の太さ・効果の半径・`clip` の矩形・断片が受ける位置と大きさ・字は、本体の面と同じく倍率を掛けて描かれます。描き場所から作った描き場所も倍率を引き継ぎます。

`image(描き場所, …)` は、置く大きさと切り出しの矩形を描き場所の座標の大きさ (`createGraphics` に渡した幅と高さ) で読み、`texture(描き場所)` と `vertex(x, y, u, v)` の `u`・`v` も同じ座標の大きさで読むので、`--scale` の有無で構図は変わりません。倍率を書かなければ、また `--scale 1` なら、描き場所の大きさも画素もこれまでと同じです。描き場所のメモリは倍率の 2 乗で増えます。置いた後に描き換える前の絵を取る写し (置き先ごとに最大 4 枚) も同じ大きさなので、その分も増えます。

**倍率 1 では描けた作品が、倍率 N では `setup()` で止まることがあります。** 描き場所にも面と同じ 16384 画素の上限があり、座標に倍率を掛けた大きさがそれを越える描き場所 (本体より大きい描き場所。たとえば `createGraphics(8192, 64)` を `--scale 3` で書くと 24576 画素) は、作る所 (`setup()` や `draw()`) で失敗します。この失敗のために、`RenderFailure` に `sizeBeyondOutputScale(width:height:scale:)` の case を足しました。倍率と、その倍率で作れる最大の大きさを名乗ります。幅・高さが 1 を割る指定や、倍率の前から上限を越える指定は、これまでどおり `invalidSize(width:height:)` です。

**`RenderFailure` を `switch` で全 case 数えている作品は、コンパイル時に `sizeBeyondOutputScale` の枝が足りないと指摘されます。** 移行: 枝を足してください。描き場所の大きさを直すか倍率を下げるよう案内する枝にするか、`createGraphics` の失敗だけを扱う `switch` なら `case .sizeBeyondOutputScale: break` のように何もしない枝で足ります。`default:` を置いていれば直す必要はありません。
