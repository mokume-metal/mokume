<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

カメラや動画の 1 枚を絵にする変換が、毎フレーム 0 で埋めた大きな配列を確保しなくなった。大きさの違う映像を縮めて読むときの一時の配列は持ち回し、出力の配列は 0 埋めを挟まずに作る。絵は 1 バイトも変わらない。
