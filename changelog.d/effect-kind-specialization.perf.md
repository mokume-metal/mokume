<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**組み込みの効果 (`invert`・`monochrome`・`vignette`・`adjust` など) が、効果の種類ごとに特化した軽いシェーダで走るようになりました。** 4K で 4 段重ねた絵で、1 フレームの GPU の待ちが約 0.15 ms 下がります。絵は 1 ビットも変わりません。代わりに、種類を初めて使うフレームで、その種類のシェーダを組む時間（数十 ms）だけ止まることがあります。
