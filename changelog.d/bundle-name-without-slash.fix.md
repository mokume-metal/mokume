<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、`mokume-app.json` の `name` に `/` があると、組み立ての前に `The name in the identity cannot contain "/"` と名指して止まるようになった ([#2309](https://github.com/mokume-metal/mokume/issues/2309))。`name` は `.app` と開き方の紙のファイル名にもなるためで、これまでは `AC/DC` で `bundle/` の下に余計なディレクトリを作って途中で止まり、`../victim` では `--out` の外にある同じ名前の `.app` を中身ごと消していた。`/` を含む表示名は付けられない。`/` の無い名前 (空白や日本語を含むもの) はこれまでどおり束ねられる。

あわせて、束ねるときに消すのは `--out` の直下にある前の版の `.app` だけになった。名前から作った場所がそこを外れたら、何も消さずに止まる。
