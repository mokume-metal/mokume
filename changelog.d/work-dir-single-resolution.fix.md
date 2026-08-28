<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`MOKUME_WORK_DIR` を立てても、道具とスケッチが同じ区画を見るようになりました。** これまで区画の基準を見ていたのはスケッチだけで、窓口は引数 ‖ 作業ディレクトリ、`watch` の作り直しの記録はパッケージの場所へ置かれていました — 環境変数を立てると、観測・記録・窓口の 3 つが別々の場所に割れていました。

**基準は 2 つの軸に分かれます。** 区画 (`.mokume/observe`・`.mokume/input`・`.mokume/build`) は `MOKUME_WORK_DIR` があればそこで、無ければいままでどおり 引数 ‖ 作業ディレクトリ。パッケージの場所 (ビルド・`Package.swift`・面の仕様と公開 API の解決) は環境変数に動かされません。`watch` は区画の基準が別のとき、それを起動時に表示します。
