<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) が、型の違う引数を既定へ黙って倒さず、断るようになった ([#2319](https://github.com/mokume-metal/mokume/issues/2319))。

- `observe` の `scale` に数でない値 (`"0.5"`・`null` など) を渡すと、黙って落として等倍で撮っていた。`true` は 1 として通っていた。いまは要求を置かずに `scale must be a number` と断る。範囲の外の数 (`0`・`2`) はこれまでどおり切らずに渡し、撮る側が等倍で書いて警告で伝える。
- `reference` に文字列でない `name` (`5` など) を渡すと、頼んだ文書の代わりに一覧を成功として返していた。いまは `name must be a string` と断る。`name` を省けば、これまでどおり一覧を返す。
- `tools/call` の `arguments` がオブジェクトでない (`"x"`・`[1]` など) と、黙って空の引数として道具を走らせていた。いまは道具を走らせず、`-32602` (`arguments must be an object`) で断る。`arguments` を省くか `null` にしたときは、これまでどおり空の引数で走らせる。
