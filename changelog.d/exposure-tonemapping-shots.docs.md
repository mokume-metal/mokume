<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`exposure(_:)` と `toneMapping(_:)` の説明に、例と絵を付けた。白を越える明るさの光を当てた同じ白い球を、`exposure` は倍率 0.5 / 1 / 2 で、`toneMapping` は `.clip` / `.roll` で 1 枚ずつ描いている。倍率を上げると一様な白に飛ぶところが広がること (球のうち、なし → 半分ほど → 8 割ほど)、`.clip` では白に飛んだところに明暗が無く、`.roll` では白に届く画素が無くなって階調が残り、0.8 より暗いところは 2 つの丸め方で画素まで同じであることを、絵で見比べられる。
