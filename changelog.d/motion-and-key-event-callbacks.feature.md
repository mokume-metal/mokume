<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

移動・引きずり・キーも**出来事として**受け取れるようにした。スケッチに `mouseMoved()` / `mouseDragged()` / `keyPressed()` / `keyReleased()` / `keyTyped()` を書けば呼ばれる (Processing / p5.js と同じ綴り)。押している間の移動は `mouseDragged()`、押していない間の移動は `mouseMoved()` になる。

`keyTyped()` は**文字を生むキーでだけ**呼ばれる。矢印・ファンクションキー・Escape・Delete・Tab では呼ばれない (手本と同じ)。押しっぱなしのキーは、手本にならって連射する。

**同じ判定によって、`key` が矢印キーで壊れなくなった。** これまでは AppKit が矢印へ返す私用領域の文字 (U+F700 台) がそのまま入っていたので、`text("キー \(key)")` のように画面へ出すと見えない文字が出ていた。

`mouseDragged()` の中で読む `dragX` / `dragY` は**フレームの累計であって 1 件ぶんではない**。1 フレームに移動が 3 件届けば 3 回呼ばれ、そのたびに部分累計になる。とくに `orbitControl()` は 1 フレームに 1 回しか引きずった量を食わないので、`mouseDragged()` の中から呼ぶと残りが黙って捨てられる — 視点を回すのは `draw()` の中から呼ぶ。
