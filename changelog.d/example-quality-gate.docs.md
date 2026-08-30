<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

説明文の中の例が実際にコンパイルできることを機械で見るようにし、腐っていた例を直した。`loadModel` の例は存在しない口 `millis()` を呼び、`read(_:)` の例も無い口を呼んでいた。あわせて参照の面の組み立てで警告を落とすようにし、読者が踏むリンク切れになっていたシンボルリンク 16 件を直している。
