<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

描画が転んだときの警告 (`Could not draw the frame: …`) が、**そのフレームで頼んだ `save()` がどうなるかを言わなかった**のを直した。転んだフレームの絵は出口へ配られないので、`save()` は次に描けたフレームの絵で書く。いまは警告が `A save() asked for in a frame that could not be drawn writes the next frame that is drawn` と言い添える。GPU が仕事を打ち切ったときの警告と同じ言い方で、書く絵と挙動は変わらない。
