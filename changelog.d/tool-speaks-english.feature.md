<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

**道具が話す言葉を英語にしていく。** `mokume-cli` の help・エラー・切り分けの口・見張りの進捗・エージェントの窓口が返す説明文、そしてスケッチ実行時に窓へ描かれる名乗りと診断は、これまで日本語だけだった。mokume で作品を作る人は日本語話者に限らないので、**道具の表示は英語**にする。

**読み物は日本語のまま。** 公開 API の説明・ADR・README・`mokume new` が生成するテンプレートは動かない。線は読み手で引いており、道具の表示を読むのは作品を作る人、読み物を読むのはこのリポジトリを触る人である ([ADR-0038](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0038-language-of-the-tool.md))。

**切替は持たない。** CLI とボタンに出るのは難しい英語ではなく、2 言語ぶんの文言を維持する機構は実害が示されてから足す。

この版で英語になったのは**使い方の案内 (`mokume help`) と、知らないコマンドを打ったときの言い方**である。残りの面は順に移す。
