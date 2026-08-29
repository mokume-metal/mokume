<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

リリースノートに組めない形の断片が `changelog.d/` に入らなくなりました。ノートを組む道具自身が `python3 scripts/release.py lint` で検査するようになり (`make ci-check` に入っています)、分類の綴り違い・分類の無いファイル名・kebab-case でない slug・空の本文・相対パスや reference style のリンクを、ファイル名を名指しして落とします。分類の語彙の正典は組む側の `SECTIONS` 1 箇所だけなので、`changelog.d/README.md` は綴りを写しません — 使える綴りは検査の出力が教えます。
