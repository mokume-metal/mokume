<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

同じフレームを PNG や `encodeForDisplay()` で書き出した絵と、録画・観測・`encodeToImage()` で取り出した絵が、ごく稀に 1 段 (8 bit の最下位) ずれていたのを直しました。量子化の境目のほぼ真上に落ちる色だけで起き、`toneMapping(.roll)` のときに多く、`clip` でも起きていました。GPU 側が伝達関数と丸めを CPU と違う計算で行っていたためで、段を CPU の計算から求めたしきい値で決め、`roll` の曲線も CPU と GPU で同じ式にしました。代わりに、`roll` の書き出しの色がごく稀に 1 段動きます (1 画素の 1 成分が 1 段、4,000 万バイトあたり数十バイト)。`clip` の書き出しは 1 バイトも変わりません。
