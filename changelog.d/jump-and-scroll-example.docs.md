<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**足場を走って跳ぶ横スクロールの作例 `jump-and-scroll` を足した** (`swift run reference-sketches jump-and-scroll`)。タイトルで return を押すと始まり、← → で走り、space で跳ぶ (足場に立っているときだけ)。コインに触れるとスコアが 10 増え、旗に触れるか穴に 3 回落ちると結果の画面になり、return でタイトルへ戻る。面は画面の 4 倍の幅で、カメラはプレイヤーを追い、面の両端で止まる。

ゲーム層の 3 つの API — 場面の切り替え (`Scene`)・重力と接地と壁 (`ArcadeBody`)・カメラの追従 (`Camera2D`) — と段 1 の値と問いだけで書いてあり、場面の切り替え・重力の積み上げ・接地の判定・めり込みの解消・カメラの追従を作例の側では書いていない。面は Swift の文字列の格子 (`#` 足場・`o` コイン・`F` 旗) で書き、資材のファイルは置かない。
