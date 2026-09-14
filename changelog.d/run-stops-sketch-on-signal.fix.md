<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume run` を SIGTERM / SIGHUP で止めると、走らせていたスケッチも一緒に止まるようになりました。** これまでは道具の PID だけに合図を送ると道具だけが終わり、スケッチは窓ごと孤児として残っていました (端末の Control + C はグループ全体に届くので、人が打つ限りは起きません — エージェントやスクリプトが止める経路で起きていました)。合図で止めた回の終了コードは慣習どおり `128 + 番号` (SIGTERM なら 143) です。
