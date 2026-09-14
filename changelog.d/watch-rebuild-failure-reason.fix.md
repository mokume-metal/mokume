<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が作り直しを起こせずに失敗した回 (`swift` が見つからないなど) は、`.mokume/build/status.json` の `output` が空になり、端末にも道具自身の言葉では `Build failed` としか出ていなかった。理由を捨てずに、`output` と端末の両方へ載せるようになった。

終了コードが 1 であることと、走っている版を落とさずに次の保存を待つことは変わらない。
