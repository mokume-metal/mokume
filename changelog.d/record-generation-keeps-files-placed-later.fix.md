<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch --record take.json` が、世代の名前 (`take-3.json` など) を選んだ後にそこへ置かれたファイルを、消したり上書きしたりしなくなりました。スケッチが立ち上がるまでに記録でないファイル (記録の頭 `{"schemaVersion":` で始まらないもの・フォルダ・シンボリックリンク) が置かれていれば、その世代は記録せず `Not recording: …` で理由を言って走り続けます。記録している間に置かれたときは、終わりで置き換えず、書き終えた記録を `take-3.json.<プロセス番号>.partial` に残して理由を言います。`mokume run --record take.json` は、これまでどおり頼まれた行き先を置き換えます。
