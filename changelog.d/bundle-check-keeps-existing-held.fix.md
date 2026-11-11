<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が表示する配布前の確認コマンドが、スケッチに `.build-held` という名前のディレクトリが既にあると `.build` を入れ子 (`.build/.build`) に戻し、`.build-held` の中身も巻き込んでいたのを直した。退避先はその回だけの一意なディレクトリ (`.build-held.XXXXXX`) になり、終わると消える。前からある `.build-held` には触れない。
