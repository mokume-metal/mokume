<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

合成音で音ごとに高さを変えながら刻む書き方 (`osc.play(freq, amp, at: t)` と `env.play(osc, …, at: t)` を同じ時刻に並べる) を `Env.play(…, at:)` の説明文に作例つきで書いた。`osc.freq(_:)` などは今すぐ効いて鳴っている音の高さも変わること、並べた形は 1 音で予約の置き場を 11 個 (およそ 186 音ぶん) 使うことも書いている。口は増えず、並べた形が予約した標本から変わることは検査で縛った。
