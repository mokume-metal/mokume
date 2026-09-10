<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

PR を作る identity のガードが、`gh pr create` の 1 綴りだけを見ていたのを直した。`gh pr new` は同じコマンドの組み込みエイリアスで、`gh pr revert` も revert PR を作るので、どちらもメンテナ名義で打てば素通しし、**誰も承認できない PR** ができていた。差し戻しの文言も、`gh pr create` の決め打ちではなく実際に打たれた口を名乗る。判定に載せない口 (`gh api` や利用者が定義したエイリアスなど) は、**載せない理由**をガードの冒頭に表として置いた — 捕まえられないものを捕まえたふりをすると、通ったことが安全の証拠と読まれるため。`gh pr create --dry-run` は PR を作らないので素通しする。
