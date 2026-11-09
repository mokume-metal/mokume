<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` と `mokume watch` が、構成を指定しないときは release で組むようになりました。普通に走らせたスケッチが最初から最適化されます。代わりに、初回と保存後の組み立ては debug より長くかかります。debug に戻すには `-c debug` を付けます (`mokume run -c debug` / `mokume watch -c debug`)。組み立ての報告が名乗る構成名も、指定が無ければ `release` になります。`mokume render` と `mokume doctor` の既定、`mokume bundle` が release で束ねることは変わりません。
