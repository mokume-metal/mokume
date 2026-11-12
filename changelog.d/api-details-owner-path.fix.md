<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

MCP の `reference(name: "api", symbol:)` が、入れ子の型のメンバを持ち主の型で引けるようにした。`PixelSurface.ColorTable.init` で `ColorTable` の初期化子だけが返り、`PixelSurface.init` には入れ子の型の初期化子が混ざらない。口ごとの詳細の資産 (`mokume-api-details-v<版>.json`) の各項目に、持ち主の経路全体の欄 `ownerPath` を足した (`owner` は最外の型のままで、`schemaVersion` も 1 のまま)。`ownerPath` を持たない古い資産は、今までどおり最外の型で引ける。
