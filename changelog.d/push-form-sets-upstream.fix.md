<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントに案内していた push が、新しいブランチではそのまま打つと落ちる形 (`git push`) だったのを直した。落ちる形を見せていたため、読んだ側がその場で各自の形に書き換えて凌ぐことになり、`-u` が付くかどうかが経路ごとに変わっていた。付かなかったブランチは merge されても `[gone]` にならず、`git gone-clean` が永久に拾えないまま手元に溜まる (実測で 18 本中 16 本が残っていた)。案内を `git push -u origin HEAD` に統一し、案内に現れる push が実行できる形であることを検査で固定した。
