<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

見張り (`mokume watch`) が、終わるときに走らせていたスケッチを止めるようになった。これまでは終わりの合図を受け取っておらず、端末以外から終わらせると (`kill` や、見張りを抱えているセッションの終了) スケッチだけが残り続けていた。
