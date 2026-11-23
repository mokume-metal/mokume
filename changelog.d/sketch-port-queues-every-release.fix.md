<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

別のアプリへ絵を渡しているスケッチが重いとき、受け手が返した面がスケッチに戻らず、その面へ二度と書かれなくなることがあったのを直した。受け手から届く頼みをスケッチが溜めておける数は OS の既定の 2 通だけで、読む前に 3 通目の `release` が届くと落ちていた ([#4060](https://github.com/mokume-metal/mokume/issues/4060))。

いまは 40 通 (受け手の上限 4 人 × (面の上限 8 枚 + 2)) まで溜める。受け手が全員、面を全部返し、繋ぎ直しと切断を 1 通ずつ重ねても収まる数で、手順書 `Schemas/frame-link.md` にも書いた。これを越えて続けて送った分は、これまでどおり待たずに落ちる。
