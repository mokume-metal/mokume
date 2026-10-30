<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `mokume watch` の端末に出る速さの行が、端末の幅に収まるようになった。`noLoop()` の間の行は推移を添えると 80 桁を越え、折り返して毎秒 1 行ずつ画面に積み上がっていた。いまは行を毎秒の端末の幅 (読めなければ 80 桁) より 1 桁短く収め、収まらない分は推移を古い秒 (左) から落とす。現在値と構成の括弧は削らない。幅が足りる端末の行は変わらない。
