<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**`beginRecord("….mov")` と `mokume render --out ….mov` が書く動画の時刻が 1/600 秒の刻みに丸められ、600 を割り切らない fps で 1 枚の長さが揃わず、600 を越える fps で枚が消えていたのを直しました。** 刻みは説明どおり 1/90 000 秒になり、48 fps なら 24 枚とも 1/48 秒、1000 fps なら 20 枚とも 1/1000 秒で入ります。90 000 を割り切らない fps (7 など) では 1 刻み (約 11 µs) の揺れが残ります。90 000 fps を越える組は書き出せないので、`mokume render` は走らせる前に `--fps` の上限を名乗って止まり、作品の `beginRecord("….mov")` は撮り始めずに 1 度知らせます。連番 (`frame-####.png`) は時刻を書かないので、これまでどおり上限なく撮れます。
