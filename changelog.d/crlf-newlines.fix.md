<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

改行が CRLF (`\r\n`) のファイルや文字列を、LF と同じように扱うようになった。Windows 系の道具が書き出した OBJ は、これまで `loadModel()` に渡すと**頂点が 1 つも無いモデルが警告も無しに返っていた** (ファイル全体が 1 行として読まれ、先頭のコメント行として飛ばされていた)。同じ理由で、CRLF を含む文字列は `text()` で改行されず 1 行として描かれていた。単独の `\r` で改行するファイルも同じ扱いになる。
