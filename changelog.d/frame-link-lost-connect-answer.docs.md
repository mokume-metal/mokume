<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**作品の絵を受け取るアプリの手順書に、接続の答えが届かない・遅れるときの立ち直り方を書きました。** 受け手の待ち行列が満杯だと、作品の答え (`accepted`・`refused`) は届かず、送り直されません。作品が忙しければ答えは遅れ、受け手からの `connect` も作品の短い待ち行列で落ちます。受け手は繋ぐ前に自分の待ち行列を読み切り (作品が消えた知らせと `resized` は捌きます)、1 つの port から答えを待つ `connect` は 1 通だけにして、受け手が選ぶ期限 (1 秒以上を勧め、続けて過ぎるたびに延ばします) まで待ちます。送れなかった `connect` は答えを待たずに送り直します。期限を過ぎたら、番号を知っていても `disconnect` は送らず、受信の port と面を作り直して繋ぎ直します。遅れて届く答えは古い port と一緒に消えます。手順は [Schemas/frame-link.md](https://github.com/mokume-metal/mokume/blob/main/Schemas/frame-link.md) にあります。
