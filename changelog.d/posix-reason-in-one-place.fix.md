<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

ディレクトリへ `saveTable` などで書こうとしたときの失敗の理由が、`No such file or directory` (在るものを無いと言う) ではなく `Is a directory` になり、同じ場所を `loadTable` で読んだときと同じ語で名乗るようになりました ([#2839](https://github.com/mokume-metal/mokume/issues/2839))。これまでは `DataFailure.unwritable` の理由が `The operation couldn’t be completed. No such file or directory` でした。

あわせて、OS が名乗る事情 (`Permission denied` など) を文にする所を 1 つにまとめました。書く側 (`unwritable`)・URL から受け取れないとき (`unreachable`)・警告の文面は、下に POSIX の事情があれば、読む側と同じ C の文面 (`Permission denied`) を名乗ります。Foundation の説明 (`The operation couldn’t be completed. …`) は使わないので、言語の設定には左右されません。シリアルポート・UDP・`mokume` の道具の文面は変わりません (OS が名乗らない番号だけ `Unknown error: N` が `error N` になります)。
