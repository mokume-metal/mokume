<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`SketchRuntime.advance()` を、main actor を譲らないループ (窓を出さない書き出しや検査のループ) で回すと、メモリがフレームに比例して増え続けていたのを直しました。GPU の仕事が終わるたびに main actor へ積んでいた後片付けの知らせが、ループが main actor を返すまで 1 本も走れずに溜まっていたためです。知らせを合体し、積むのは 1 本までにしました。ファイルから読んだ断片 (`loadShader` など) の見張りも同じ形で、保存や書き出しの行き先が同じディレクトリだとフレームごとに知らせを積み、譲った後に溜まった回数だけ読み直していました。こちらも 1 本までにしました。
