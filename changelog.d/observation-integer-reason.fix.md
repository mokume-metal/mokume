<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

観測の要求の `count`・`every`・`scale` に、型に収まらない数 (`count: 2.5`・`count: 1e19`・`scale: 1e400` など) を書いたときの応答が、どの鍵の何が悪いかを名乗るようになった。これまでは `warnings` が鍵を言わず「The given data was not valid JSON」と言い、構文の誤りを探しに行かされていた。

いまは `count` のような鍵と、その値が整数 (`scale` なら `Double`) に収まらないことを言う。理由に数の字面は写さないので、桁の多い数でも 1 行は伸びない。
