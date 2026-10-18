<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SoundFile` に、いま鳴らしている位置 `position` (秒)・長さ `duration` (秒)・その秒へ飛ぶ `jump(_:)` を足した。名前は Processing Sound に倣い、単位と振る舞いは `Movie` の `time`・`duration`・`jump(_:)` に揃えた。曲の位置で場面を切り替える (`if song.position < 62 { … }`)・サビから確かめる (`song?.jump(62)`) が、鳴らし始めた時刻を覚えて引く自作の時計なしに書ける。

`jump(_:)` は呼んだ直後から `position` が飛び先を返し、鳴っている間は次のフレームからその位置の音が鳴って解析の値も移る。止めている間は位置だけを動かし、次の `play()` がそこから鳴らす。0 より前と長さより後は端へ寄せ、数でない値は位置を変えずに 1 度だけ知らせる。書き出し (固定の時計) では位置がフレームの数で決まるので、同じフレームはいつも同じ曲の位置で描かれる。
