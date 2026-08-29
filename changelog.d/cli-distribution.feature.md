<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

道具を入れられるようになりました。Release の資産に実行ファイルが載るので、ライブラリを clone しなくても `curl -fsSL https://github.com/mokume-metal/mokume/releases/latest/download/mokume-macos-arm64.tar.gz | tar xz -C ~/.local/bin` の 1 行で入ります (置かれるのは道具 `mokume` と、ひな形の入った `mokume_MokumeCLI.bundle` の 2 つで 1 組)。**利用者が打つ名前は `mokume` です** — これまで README は `mokume-cli` で案内していましたが、道具の案内文も起動された名前で名乗るようになったので、印字された行はそのまま打てます (開発中の `swift run mokume-cli` でも同じ)。
