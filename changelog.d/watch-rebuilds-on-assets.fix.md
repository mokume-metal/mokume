<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が、資材の置き場 (`Sources/<名前>/assets/`) のファイルを足したり描き換えたりしたときも作り直すようになった ([#2312](https://github.com/mokume-metal/mokume/issues/2312))。これまでは `.swift` と `Package.swift` だけを見ていたので、資材だけを変えても作り直さず、走っているスケッチはビルドが写した古い資材を読み続け、どれかの `.swift` を保存してはじめて新しい資材になっていた。置き場の `.metal` と隠しファイル (`.DS_Store` など) は、これまでどおり作り直しを起こさない。

見張りは 0.25 秒ごとに見に行くが、大きさ・更新時刻が前回から変わっていないファイルは読み直さない。置き場に動画やモデルのような大きなファイルを置いても、変えていなければ読む量は増えない。
