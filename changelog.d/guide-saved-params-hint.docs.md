<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new` が置く案内 (`AGENTS.md`) に、`@Param` の既定値を書き換えても絵が変わらないときは `.mokume/state/params.json` の保存値を疑う、という行を足した。起動時に名前と型が一致する保存値がコードの既定値に勝つので、つまみで一度でも合わせた値は既定値を直しても残る。保存値を消す・書き換えるのは、合わせた値が失われるため人に確かめてからにする。
