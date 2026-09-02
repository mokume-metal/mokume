<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` のプレビューに**つまみが出る**ようになった。宣言と値は既にある `.mokume/params` を通り、**新しい経路は作っていない** ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 1 は変わらない — 変わるのは重ねる窓だけ)。**作品の窓には出ない**ので、見張りから本番を回している間、つまみが本番の画面に出ることはない。

これで [ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 5 が書いていた退行 (見張りから起こした子でつまみが見えない期間) は終わる。

見張っている間は `.mokume/params` を道具が用意する。**元から在った区画は畳まない** — 外から動かすために人が置いたものかもしれないため。
