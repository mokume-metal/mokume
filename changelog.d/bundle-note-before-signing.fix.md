<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`mokume bundle` が、開き方の紙を署名より前に書くようになりました。** これまでは紙が書けない回 (`--out` に同じ名前のディレクトリがあるなど) に、署名済みの `<name>.app` が残ったまま 1 で終わっていました。いまは署名の段に進む前に同じ失敗で止まります。あわせて README に、名前の検めを通っても組み立ての後で止まりうる形 (長さ以外で APFS が断る名前・パスが 1024 バイトを越える深い `--out`・exFAT / FAT32 の置き場) を書きました。
