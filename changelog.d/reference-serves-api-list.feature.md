<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

窓口から**公開 API の一覧**を読めるようになりました (`reference` に `name: "api"`)。繋いだエージェントは、何が呼べるかを知るためにライブラリのソースを読まなくてよくなります。

引くのは**依存として解決された版ぴったりの一覧**です。`.mokume/reference/` に取り置いたものがあればそれを返し、無ければ `Package.resolved` が指す版の Release 資産を取ってきて取り置きます — 2 度目からはネットワークに触りません。版が引けない (開発中の本体をパスで指している) ときや、その版に資産が無いときは、`make api-list OUT=...` で置く**次の一手**を添えて答えます。応答の頭には**どこから得たか**が出ます。
