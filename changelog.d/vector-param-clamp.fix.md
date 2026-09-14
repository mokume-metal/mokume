<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

範囲つきで宣言した組 (`SIMD2<Float>` / `SIMD3<Float>`) へ `.mokume/params` から範囲の外の値を書くと、成分ごとに宣言した範囲へ収まり、収めたことが応答の `clamped` に載るようになった。保存からの復元で範囲が縮んでいた場合も同じである。

これまでは窓のつまみでは範囲に縛られるのに、外から書くと範囲の外の値がそのまま入り、応答も何も言わなかった — 人が窓で動かすときと道具が外から書くときで、同じ宣言が違う意味になっていた。

応答 (`.mokume/params/report.json`) の `schemaVersion` は 2 になった。`clamped[].requested` / `.value` の形が宣言の型に従う (数は数・組は成分の配列) ようになったためで、1 のときは常に数だった。
