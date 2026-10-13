<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume new <名前>` が、作ったあとに `swift build` で組めなくなる名前を、何も書く前に断るようになった。理由と別の名前の例を言って終了コード 1 で止まる。

これまでは `mokume new sketch` が `Created` と言って、組めないパッケージを作っていた (`'Sketch' inherits from itself`)。断るのは、ひな形が使う mokume の型と同じ型名になる名前 (`sketch`・`sketch-settings`)、型名にできない `Self`・`Any`、mokume 自身や import するモジュールと同じ名前 (`mokume`・`MokumeCore`・`Foundation` など)、`--local` が指す場所の末尾と同じ名前。`my-sketch`・`café`・`Type` などいままで組めた名前は、いままでどおり作られる。
