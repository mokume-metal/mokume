<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Examples

`mokume` コマンド (`mokume examples` / `mokume new <名前> --from <例>`) に同梱する作例のディレクトリ。

**中身は生成物で、コミットしない。** ドキュメントコメント (`///`) の中の例から `scripts/bundle-examples.py` が生成する
(`make cli-examples`。配布物を作る `make cli-dist` は、これを先に実行する)。このファイルだけが追跡されるのは、
リソースの宣言 (`Package.swift` の `.copy("Examples")`) がこのディレクトリの存在を必要とするからで、作例を生成していない手元でも
`swift build` が通るようにしてある。作例を生成しないまま実行した `mokume` コマンドは、作例が無いことを表示する。

形式と選ぶ規則は `scripts/bundle-examples.py` の冒頭、読み込む側は `Sources/MokumeCLI/Examples.swift`。
