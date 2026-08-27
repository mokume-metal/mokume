// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// アンブレラ — 全モジュールを再エクスポートし、利用者の入口を 1 つに保つ
// (ADR-0016 決定 2)。内部の層構造が利用者の書き味に漏れないようにするためで、
// 層を再編成しても利用者のコードは `import mokume` のまま変わらない。
//
// モジュールが増えたら、ここに 1 行足す。

@_exported import MokumeCore
