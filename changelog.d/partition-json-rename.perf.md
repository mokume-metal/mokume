<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` の区画 (`.mokume/<区画>/`) に毎フレーム書き直すファイル (つまみの応答・入力の応答・観測の目録・つまみの要求・build record・共有面の目録) の置き換えを、`FileManager.replaceItemAt` から `rename(2)` 1 回に変えました ([#2382](https://github.com/mokume-metal/mokume/issues/2382))。`draw()` の中で `@Param` を毎フレーム動かす作品 (13 個のつまみ) で、main が区画へ応答を置く時間と syscall の数が縮みます。読み手が半端なファイルを見ないことは同じです。

置いたファイルの権限・拡張属性・作成日時は、置き換え前のファイルから引き継がず、一時ファイルのもの (権限は 0644 など) になります。つまみの値の保存 (`.mokume/state/params.json`) と作品の出力 (画像・動画など) は、これまでどおり属性を引き継ぐ置き換えです。

置き先がシンボリックリンクのとき、これまで区画へ置けず警告で失敗していましたが、リンク自身が普通のファイルに置き換わるようになります (指す先は変わりません)。
