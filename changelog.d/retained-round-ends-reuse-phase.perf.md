<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

丸い端 (既定) の細い線を持つ `createShape()` の形を、副画素ずつ動かして置き続けても、置くたびに組み直さず控えた片を使い回すようにした。細かさ 0.5・頂点 200 の線の形 100 個を毎フレーム動かす場面で、1 フレームの CPU 時間が 5.9 ms から 1.0 ms になった。光の量は変わらない (±0.1% 以内) が、端の画素の濃さはその場で引いた線と最大 0.2 ほど違うことがある ([#3864](https://github.com/mokume-metal/mokume/issues/3864))。
