<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**作品の絵を受け取るアプリの手順書に、接続の答えが届かなかったときの立ち直り方を書きました。** 受け手の待ち行列が満杯だと、作品の答え (`accepted`・`refused`) は届かず、送り直されません。受け手は繋ぐ前に自分の待ち行列を読み切り、答えを期限つきで待ちます。期限を過ぎたら、番号を知っていれば `disconnect` してから、知らなければ受信の port を作り直してから繋ぎ直します。作品の側の振る舞いは変わりません。手順は [Schemas/frame-link.md](https://github.com/mokume-metal/mokume/blob/main/Schemas/frame-link.md) にあります。
