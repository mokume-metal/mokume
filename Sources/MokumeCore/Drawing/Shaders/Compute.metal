// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 計算の断片に**無条件で**前置きされる共通部分。
//
// 塗りの共通部分 (Common.metal) と違って、ここは入口の関数を用意しない。塗りは
// 「その画素の色」を返すだけで済むが、計算は**どの並びを読み書きするかが断片ごとに
// 違う**ので、口の数と並びを仕組みが決めてしまうと、決めた数を超えた瞬間に使えなく
// なる。書く側が入口ごと書く形にしてある。
//
// 束ねる先の番号は呼ぶ側が決める — compute(_:over:reads:writes:) に渡した
// reads + writes の並びが、そのまま buffer(0), buffer(1), … になる。

#include <metal_stdlib>
using namespace metal;

// 利用者が渡した値 (Values) が載る口。**番号を書き写さずに済むよう名前で配る** —
// 番号は仕組みの都合で動きうるが、この名前は動かない。
#define MOKUME_VALUES 15
