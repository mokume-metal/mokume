<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画の土台が入りました。半精度浮動小数のオフスクリーン描画先を確保して色で塗り、その内容を CPU 側へ読み出せます。作業空間は線形の色で、表示できる範囲を超えた明るさや色域の外側の値も、出力段まで捨てずに保持します。
