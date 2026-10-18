<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`@Param` の初期値や範囲の端に非有限の数を書いても、値の保存とつまみの応答が止まらなくなりました。** これまでは `@Param var radius: Double = .nan` (`init` の中で `radius = .nan` と代入した場合も) や `@Param(0...Double.infinity) var r: Double = 1` と書くと、起動の時点から `.mokume/state/params.json` に他の値も含めて何も保存されず、watch の窓のつまみも動きませんでした。

いまは、非有限の初期値は型の零 (`0`・`SIMD2(0, 0)`・4 成分とも 0 の色) から始まり、端が非有限の範囲は面に出しません (窓のつまみは出ず、応答に `min` / `max` を書きません。外からの書き込みは、有限の端があれば今までどおりそこへ収めます)。どちらも標準エラーへ 1 度だけ知らせます。
