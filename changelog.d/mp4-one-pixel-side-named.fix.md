<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**幅か高さが 1 の作品を `mokume render --out x.mp4` で書き出すと、0 バイトのファイルを黙って残さず、書けないことを名乗って終わるようになりました。** これまでは、書き出しの子は何も知らせず終了コード 0 で終わり、道具は「スケッチと道具の版が食い違う」と推して `mokume doctor` を勧めていました。いまは `Could not write …: an H.264 movie needs at least 2 pixels on each side` と大きさを名指して 1 で終わります。書き手が空のファイル (または標本の無い動画) を書いて閉じてしまった場合も、閉じるときに見つけて名乗ります。道具の側も、動画の行き先に空のファイルが残ったときは、版の食い違いと決めつけず、書き手が何も書かなかった場合と両方を挙げて案内します。
