<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

光と周囲の 8 口 (`ambientLight` / `directionalLight` / `pointLight` / `spotLight` / `lights` / `noLights` / `surroundings` / `background(Surroundings)`) に、引数を 1 つずつ動かした例と絵を 9 枚付けた。`lights()` の絵は中身 (底上げの光 + 斜め上から差す光) を 3 つ並べて示していて、3 つ目の暗い側が 1 つ目と同じ明るさで止まることが画素で確かめられる。`background(Surroundings)` の絵は、背景に空を描きながら夕暮れを映り込ませて「置くのと描くのは別」を 1 枚にしている。
