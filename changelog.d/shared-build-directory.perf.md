<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` / `mokume watch` のビルドの置き場を、スケッチごとではなく**版ごとに共有**するようにした。置き場は `~/Library/Caches/mokume/build/<道具立て>/<mokume の版>` で、2 本目以降のスケッチは **22.2 秒 / 414MB から 2.5 秒 / 14MB** になる (実測)。1 本のスケッチが持っていた 414MB のうち、そのスケッチに固有なのは 14MB だけだった。

同じ名前のスケッチが 2 つあるときは、先に走ったほうが共有の置き場を使い、後から来たほうは今までどおり自分の `.build` に建てて**そう名乗る** — 黙って別のスケッチの実行ファイルを起動しないようにするためである。mokume 自身をパスで指しているスケッチ (`mokume new --local`) は、これまでどおりソースから自分の `.build` に建てる。

置き場を明示したいときは `mokume run <場所> --scratch-path <置き場>` で渡せる。根そのものを変えるなら `MOKUME_BUILD_DIR` を与える。在処と大きさは `mokume doctor` が名乗る。

判断の詳細は [ADR-0037](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0037-shared-build-directory.md)。
