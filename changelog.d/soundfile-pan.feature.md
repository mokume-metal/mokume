<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SoundFile` に左右の定位を決める `pan(_:)` を足した。-1 で左、0 で中央、1 で右で、ウィンドウで鳴る音にも、`mokume render --out x.mov` の音声トラックにも同じ定位で入る。

モノラルのファイルは、中央で左右とも元の大きさになる、左右を合わせた大きさが変わらない定位で、端では片側が元の √2 倍 (+3 dB) になる。ステレオのファイルはバランスで、反対側だけを下げる。`level` などの解析の値は定位で変わらず、エフェクトに通したファイルはエフェクトの出力で中央のまま。既定 (`pan(0)`) では、これまでと 1 サンプルも変わらない ([#3473](https://github.com/mokume-metal/mokume/issues/3473))。
