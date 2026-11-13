<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` を止めずに作り直す `rebuild` と、作り直さずにいまの版を最初から起こし直す `restart` を、区画 `watch` の要求 (`.mokume/watch/request.json`) で頼めるようにしました。`resources: [.process("Resources")]` の画像のように見張る範囲の外を変えたときも、`{"id": "r1", "action": "rebuild"}` を置けば保存したときと同じ作り直しが 1 回起き、`watch` を起こし直す必要がありません。

- `rebuild` は中身が変わっていなくても 1 回作り直します。作り直しの最中に頼むと、済んだ後に 1 回だけ続けます。試聴の中で頼めば試聴の版、そうでなければ本番の版で、保存と同じ規則 (頼みを読んだ時点で決まる) に従います。作り直しの記録 (`build_status`) は `requested: "rebuild"` を持ちます
- `restart` は時刻を 0 から始めます (`--keep-time` で起こした見張りでも)。試聴中なら試聴の子、そうでなければ本番の子に当たります。当たる子が走っていなければ `noTarget`、最後に通った作り直しが残した版が当たる子の版でなければ `notBuilt` で断ります (試聴の版を作った後など。そのときは `rebuild` を使います)。記録は書きません
