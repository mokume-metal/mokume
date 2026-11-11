<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、テストの target だけが宣言した資材 (fixture など) まで配布用の `.app` に入れていたのを直した。入れるのは実行 product が依存で辿る target の資材と、依存のパッケージの資材だけになる。資材が揃っているかの検査も同じ範囲を見るので、除いたテストの資材を「欠けている」と言って止まることもない。
