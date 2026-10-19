<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

マイクと合成音の解析で、読み取り中の標本が上書きされるデータ競合を修正した。描画側が長く止まっても音声側を待たせず、一つの公開済みの窓を対応する時刻とともに読み取る。
