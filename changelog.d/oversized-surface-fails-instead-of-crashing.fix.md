<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

大きすぎる面 (`createGraphics` / `createImage` / 窓の大きさ) を頼んだとき、プロセスごと落ちずに失敗として返るようになった。

これまでは寸法の下限しか見ていなかった。Metal は上限を超えた面に `nil` を返さず、検証層のアサーションでプロセスを終了させるので、`try` を書いても書かなくても結果は同じ (どちらもスケッチが消える) で、失敗を扱う手立てが無かった。いまは面の一辺が 16384 画素を超えていれば、Metal に渡す前に断る。文面は上限そのものを名乗る。
