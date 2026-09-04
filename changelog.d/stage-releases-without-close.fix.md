<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

作品の窓とプレビューを `close()` せずに手放したとき、窓の裏側が解放されないまま、画面のリフレッシュのたびに区画を読み直し続けていたのを直した。手放した時点で畳まれる。
