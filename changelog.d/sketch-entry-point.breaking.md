<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new` が作るスケッチの入口が `@main` になりました。これまでは一番下に
`MySketch.main()` と書く形でしたが、**その形は対象の中身が 1 つだけのときしか通りません** —
資材を 1 つ置いた時点で組み上がらなくなります。

既にあるスケッチは、末尾の `<型名>.main()` を消し、型の宣言に `@main` を付けてください。
