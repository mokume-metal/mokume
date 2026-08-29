// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// アンブレラ — 全モジュールを再エクスポートし、利用者の入口を 1 つに保つ
// (ADR-0016 決定 2)。内部の層構造が利用者の書き味に漏れないようにするためで、
// 層を再編成しても利用者のコードは `import mokume` のまま変わらない。
//
// モジュールが増えたら、ここに 1 行足す。

@_exported import MokumeCore

// 三角関数は宣言単位で名指しして通す (ADR-0020 決定 7)。
//
// スケッチで時刻から位置を出すのは最初の 1 行目にやることで、そこで `import Foundation`
// が 1 行増えるのは「スケッチにボイラープレートを要求しない」(ADR-0001 原則 1) の縁に
// 触れる (#193)。
//
// **モジュールを丸ごと再輸出しない。** `@_exported import Foundation` はここを通るが、
// アンブレラのシンボルグラフが 737 → 10,784 に膨らみ、`scripts/api-surface.py` が
// Foundation の型を「自前」と判定して閉包の検査が既存宣言 9 本を落とす (#193 で実測)。
// 丸ごと許すと、以後その語彙が何本面に出ても検査は黙る (ADR-0020 決定 6)。
//
// 名指しの境界は手本に置く — Processing / p5 が持つ三角関数はこの 7 本ちょうどで、
// mokume は既に radians を採っている (`rotate(_ radians: Float)`) ので単位の齟齬が無い。
// 角度の単位変換・補間・写像は**ここに足さない**。「毎回書いている」ものが作品トラック
// (ADR-0022) から見えてから決める (ADR-0001 原則 4・#193)。
@_exported import func Darwin.sin
@_exported import func Darwin.cos
@_exported import func Darwin.tan
@_exported import func Darwin.asin
@_exported import func Darwin.acos
@_exported import func Darwin.atan
@_exported import func Darwin.atan2
