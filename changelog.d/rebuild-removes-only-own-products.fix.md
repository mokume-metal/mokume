<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`run` / `watch` / `bundle` の作り直しが、先に消す前の産物を、ビルドの置き場の直下にある自分の実行ファイルと dSYM だけに限るようになった。

`Package.swift` の executable product の名前が `..`・`.` や `/` を含むと、作り直しは置き場の外 (置き場の親など) や置き場そのものを消していた。いつもの名前では何も変わらない。
