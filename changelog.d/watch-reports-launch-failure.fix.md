<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume-cli watch` が作り直しの後にスケッチを起こせなかったとき、その理由を記録 (`.mokume/build/status.json` の `output`) と端末に出すようになりました。これまでは `Rebuilt, but could not start it` と出るだけで、場所が消えたのか実行できないのかがどこにも残りませんでした。理由は `output` の頭に置き、作り直しの出力はその後に続きます。見張りを終えるところで作り直しが通り、起こさなかった回も、そう名乗ります。

あわせて、`mokume-cli run`・`watch` が実行ビットの無いスケッチを「走らせるものが無い (Package.swift の products を見よ)」と言っていたのを直し、実行できないこと (`Permission denied`) と在処を名乗るようにしました。
