<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

外から送る入力で、**意味を持つ既定値が無い値が欠けていたら、その 1 件を受け取らなくなった**。位置の出来事 (`mouseDown` / `mouseUp` / `mouseMoved`) には `x` と `y`、キーの出来事 (`keyDown` / `keyUp`) には `code` が要る。これまでは欠けていると 0 で埋めていたため、`{"type":"mouseDown"}` という壊れた 1 件が「面の左上角を押した」という正しい操作として走っているスケッチへ届き、送り手にも `accepted: 1` が返るので誰も気付けなかった (`code` の 0 は実在のキー符号 A なので、`{"type":"keyDown"}` は「A を押した」になっていた)。**移行**: 位置には `x` / `y` を、キーには `code` を明示的に載せる — 省略していた送り手は、その 1 件が `ignored` に数えられるようになる (同じ要求の残りの出来事はこれまでどおり通り、走っているスケッチも止まらない)。`button` (0 = 主釦)・`dx` / `dy` (0 = 動かない)・`characters` (空)・`isRepeat` (false) は引き続き省略できる。
