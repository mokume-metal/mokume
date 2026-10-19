<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`pixels[x, y]` と `get()` / `set()` で画素を 1 つずつ読み書きするループが、画素ごとに GPU の決着を頼み直さなくなり、およそ半分の時間で回るようになりました。** 全画素を二重ループで書き換える書き方（`pixels[x, y] = pixels[x, y]`）は、1280×720 でこれまでの約 0.5 倍の時間です。読み書きの意味（書いてよい区間、効果が二重に掛からないこと、形の組み立ての中で書かないこと）は変わりません。
