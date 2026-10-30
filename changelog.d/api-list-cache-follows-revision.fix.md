<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume mcp` の `reference(name: "api")` が、枝・改訂で mokume に依存するスケッチで、改訂を上げても古い API 一覧を返し続けていたのを直しました。** 枝や改訂で固定した依存の一覧は、改訂ごとの名前 (`.mokume/reference/mokume-api-rev-<改訂の先頭 12 字>.md`) に取り置くようになり、案内の `make api-list OUT=…` もその名前になります。改訂を上げると別の名前になるので、古い一覧は返りません (置き直しが要ります)。以前に `mokume-api.md` へ置いた一覧は、枝・改訂の依存では読まれなくなります。パスで指す依存など、版も改訂も引けないときは従来どおり `mokume-api.md` を読み、答えの `Source` が「版にも改訂にも結び付かない手置きの一覧」と名乗ります。
