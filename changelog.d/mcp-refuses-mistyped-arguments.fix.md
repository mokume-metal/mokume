<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (`mokume mcp`) が、型の違う引数を既定へ黙って倒さず、断るようになった ([#2319](https://github.com/mokume-metal/mokume/issues/2319))。

- `observe` の `scale` に数でない値 (`"0.5"`・配列など) を渡すと、黙って落として等倍で撮っていた。`true` は 1 として通っていた。`-1e400` (JSON の読み手が負の無限大に読む) は、置き場所の書き込みを疑わせる見当違いの案内で失敗していた。いまはどれも要求を置かずに `scale must be a finite number` と断る。範囲の外の数 (`0`・`2`) はこれまでどおり切らずに渡し、撮る側が等倍で書いて警告で伝える。
- `reference` に文字列でない `name` (`5` など) を渡すと、頼んだ文書の代わりに一覧を成功として返していた。いまは `name must be a string` と断る。`name` を省けば、これまでどおり一覧を返す。
- `tools/call` の `arguments` がオブジェクトでない (`"x"`・`[1]` など) と、黙って空の引数として道具を走らせていた。いまは道具を走らせず、`-32602` (`arguments must be an object`) で断る。**空の配列 `[]` も断る** — 空の連想配列を `[]` と書き出すエンコーダ (PHP の `json_encode([])` など) を使う繋ぎ手は、これまで通っていた呼び出しが断られるので、`{}` を送るか `arguments` を省く。`arguments` を省くか `null` にしたときは、これまでどおり空の引数で走らせる。

`scale`・`name` に `null` を渡したときは、これまでどおり省いたのと同じに扱う。
