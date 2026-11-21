<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` のプレビューの窓が、作り直しの間に `swift build` の段数 (`42 / 44` のような「済んだ段 / いま分かっている段」) を回る印の横に添えるようになりました。分母はビルドの途中で増えることがあるので、割合ではなく段数で見せます。端末・記録・MCP への出力は変わりません ([#4121](https://github.com/mokume-metal/mokume/issues/4121))。
