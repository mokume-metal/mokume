<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ブラウンノイズ (`createBrownNoise()` で作る `BrownNoise`) を鳴らせるようになりました。Processing Sound の `BrownNoise` に当たり、高い帯域ほど急に弱まる、ピンクノイズよりさらに低くこもった音です。使い方は `WhiteNoise`・`PinkNoise` と同じで (`play`・`set`・`amp`・`pan`・`stop`)、同じ順に作れば何度鳴らしても書き出しても同じ音になります。
