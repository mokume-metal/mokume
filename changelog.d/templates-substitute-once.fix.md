<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume-cli new` がひな形へ値を差し込むとき、差し込んだ値の中の `{{TYPE}}` などを別の値で置き換え直さないようにした。

`new s --local '/libs/{{TYPE}}'` のように `{{` を含む場所を渡すと、実行のたびに `Package.swift` の中身が変わりうる状態だった (差し込む順がプロセスごとに変わるため)。いつも打ったとおりの場所が書かれる。
