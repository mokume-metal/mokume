<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume new` の直後に MCP の `reference(name: "api")` を呼ぶと、mokume 本体で `make api-list` する手順ではなく、スケッチで依存を解決する手順が返るようになった。** まだ `Package.resolved` が無いスケッチは、依存の版が決まっていないだけである。`swift package resolve --package-path <スケッチ>` を打ってからもう一度呼べば、解決された版の API 一覧を取ってくる (別の版で穴埋めはしない)。mokume をパスで指している (本体の開発) とき・枝や改訂で固定しているとき・スケッチでない場所で窓口を立てたときは、それぞれの事実に沿った案内が返る。

**`mokume doctor` の依存の行も、まだ解決していないスケッチを「パスで指している」とは言わなくなった。** `not resolved yet` と名乗り、`mokume run` か `swift package resolve` で解決することを案内する。
