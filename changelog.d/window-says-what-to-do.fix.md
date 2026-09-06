<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口 (MCP) が、区画へ要求を置けなかったときに打つ手を言うようになった。これまでは `NSCocoaErrorDomain Code=513 …` がそのまま返っており、権限の問題なのか置き場の問題なのかを読み取る手掛かりが無かった。いまは置けなかった場所と、書ける権限・ディスクの空き・`MOKUME_WORK_DIR` を確かめる手順が返る。

`observe` の引数の説明に上限が入った。`count` と `every` に `minimum` / `maximum` が載るので、繋いでいる側は上限を超えた要求を送る前に気付ける (これまでは送れてしまい、スケッチ側で切り詰められてから応答の `warnings` で知るしかなかった)。
