<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new` は、スケッチの名前に `MokumeMac` を使うと断るようになった。macOS の単独のウィンドウの外枠 (ウィンドウ・表示リンク・カーソル・つまみの UI・`Sketch.main()`) を MokumeCore から macOS 専用の内部モジュール `MokumeMac` へ移したので、その名前のスケッチは、ライブラリのモジュールと名前がぶつかって組めなくなるためである。書き手に見える違いはこれだけで、`import mokume` で書いたスケッチ・`Game.main()`・`SketchView`・`HeadlessRun` の書き方と振る舞いは変わらない (`import MokumeHost` のウィンドウなしの実行は、これまでどおり macOS では AppKit とリンクし、ウィンドウは開かない)。
