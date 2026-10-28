<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**幅か高さが 1 の作品を `mokume render --out x.mp4` で書き出すと、0 バイトのファイルを黙って残さず、書けないことを名乗って終わるようになりました。** これまでは、書き出しの子は何も知らせず終了コード 0 で終わり、道具は「スケッチと道具の版が食い違う」と推して `mokume doctor` を勧めていました。いまは `Could not write …: an H.264 movie needs at least 2 pixels on each side` と大きさを名指して 1 で終わります。書き手が空のファイルを書いて閉じてしまった場合も、閉じるときに見つけて名乗ります。道具の側も、この回に作られた空のファイルを版の食い違いとは言わなくなりました。
