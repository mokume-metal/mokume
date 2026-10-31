// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 音を実際に鳴らす入り口の目印 ([#3570])。
///
/// 窓に出して動かす実行では音は実時間で鳴り、窓を持たずに数で進める実行 (書き出し・検査・記録を流す側) では
/// フレームの数で進む。音の解析値 (`level`・`spectrum` など) を絵に使う作品は、窓で録った記録を窓なしで流すと
/// 割れうるので、窓で録った記録は、この目印の入り口を使ったことを `unreproducible` に名乗る
/// (``SketchRuntime/startRecording(_:)``)。
///
/// 外から値が届く入り口 (``Inlet/report`` を持つもの。マイクなど) はこの目印を要らない — 届く値が記録に載らないので、
/// 別の理由で名乗る。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
///
/// 目印だけで要件を持たない。``Inlet`` を継がせないのは、入り口の適合が main actor に隔離されていて、
/// それを継ぐと下限の Swift (6.3) が目印の適合まで隔離の越境と拒むため。入り口は `Inlet` と並べて適合する。
package nonisolated protocol RealtimeSound {}
