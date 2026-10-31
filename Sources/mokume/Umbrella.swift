// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// アンブレラ — 全モジュールを再エクスポートし、利用者の入口を 1 つに保つ
// (ADR-0016 決定 2)。内部の層構造が利用者の書き味に漏れないようにするためで、
// 層を再編成しても利用者のコードは `import mokume` のまま変わらない。
//
// モジュールが増えたら、ここに 1 行足す。

@_exported import MokumeAudio
@_exported import MokumeCamera
@_exported import MokumeCore
@_exported import MokumeGame
@_exported import MokumeGamepad
@_exported import MokumeMIDI
@_exported import MokumeNetwork

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
//
// **角度の単位変換・写像・補間・締め・窓は、ここではなく自前で書いた** (#883・#1281・
// #1283)。`radians` / `degrees` / `map` / `lerp` / `constrain` / `norm` / `smoothstep` に
// 対応する関数は Darwin に無いので、名指しで通せる先が最初から無い。**simd の
// `smoothstep` は形が違う** — ベクトルだけを受け、`x` を先に取る (`smoothstep(_:edge0:edge1:)`)
// ので、名指しで通すと断片 (MSL) の並びと食い違う。引数ラベルが違うので、利用者が
// `import simd` しても呼び出しは曖昧にならない。実装は MokumeCore の側
// (Math/NumberSurface.swift) にあり、上の行が MokumeCore を丸ごと再エクスポートするので
// そのまま通る。保留していた理由 — 「毎回書いている」ものが作品トラック (ADR-0022) から
// 見えていない — は、どれも 2 作品が同じ形を書いたことで解けた (ADR-0020 決定 7 の
// 2026-09-05 / 2026-09-22 改訂・ADR-0001 原則 4・#193・#1283)。
@_exported import func Darwin.sin
@_exported import func Darwin.cos
@_exported import func Darwin.tan
@_exported import func Darwin.asin
@_exported import func Darwin.acos
@_exported import func Darwin.atan
@_exported import func Darwin.atan2

// 計算の関数 7 本も、同じ基準で名指しして通す (ADR-0020 決定 7・#2416)。Processing の
// Calculation が持つ `pow`・`sqrt`・`exp`・`log`・`floor`・`ceil`・`round` で、標準ライブラリに
// あるのは `abs`・`min`・`max` だけなので、`pow` には代わりが無い。これで `import Foundation`
// を足さずに書ける (雛形も `import Foundation` を持たない)。
//
// 丸ごと再輸出しない理由は上と同じ。**手本が持たない Darwin の関数は通さない** — `cbrt` や
// `hypot` を通すと、名指しの境界が手本ではなく Darwin の品揃えになる。`dist`・`mag`・`sq`・
// `fract`・`mod` は Darwin に無いか形が違うので、MokumeCore の側に自前で書いた
// (Math/NumberSurface.swift)。Darwin の口は `Float`・`Double` の多重定義のまま届く。
@_exported import func Darwin.pow
@_exported import func Darwin.sqrt
@_exported import func Darwin.exp
@_exported import func Darwin.log
@_exported import func Darwin.floor
@_exported import func Darwin.ceil
@_exported import func Darwin.round
