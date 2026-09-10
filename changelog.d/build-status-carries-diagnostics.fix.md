<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

見張り (`mokume watch`) の作り直しの記録 (`.mokume/build/status.json`) に、失敗の本文が載るようになった。これまで載っていたのは子の標準出力だけで、**`Package.swift` で転んだ回は記録がほぼ空だった** — 端末で見ている人には理由が流れるが、窓口 (`mokume mcp`) の `build_status` から読むエージェントには「失敗した」だけが届いていた。
