<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

エージェントの窓口が付きました。`claude mcp add mokume -- mokume mcp` のように繋ぐと、走っているスケッチを撮る (`observe`)・直近の作り直しの結果を読む (`build_status`)・入力を送る (`input`)・面の仕様を読む (`reference`) が使えます。窓口は `.mokume/` の区画を読み書きするだけの薄い層で、**自分でスケッチを立ち上げたり作り直したりしません** — 見張っている `mokume watch` があればそこに相乗りし、無ければ「見張る道具を起動してください」と答えます。
