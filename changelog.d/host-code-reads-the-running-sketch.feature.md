<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchView` の隣のボタンの処理のようなホストのコードから、スケッチのメソッドを呼んで `width`・`random()` などを読めるようになった。これまではフレームの外なので 0 が返り、警告が出ていた。スケッチのメソッドはそのスケッチ自身の実行を、部品 (`SketchPart`) のメソッドは映しているスケッチが 1 つならそれを読む。描く口 (`circle` など) は、これまでどおりフレームの外では何もせず警告する ([#3847](https://github.com/mokume-metal/mokume/issues/3847))。
