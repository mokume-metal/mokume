<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

続けて転んだ差込口を外したときの診断が、**外した差込口の型ではなく `Outlet` / `Inlet` とだけ名乗っていた**のを直しました。差込口を幾つも付けたスケッチでは、どれが外れたのかが行から分かりませんでした。いまは `FrameRecorder failed again and again, so it was detached …` のように、外した差込口の型の名前で始まります (自作の差込口なら、その型の名前)。文面の残りは変わりません。
