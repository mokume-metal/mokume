<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

目録に載ったスケッチへ別のアプリが繋ぐと、そのアプリが用意した面へ、画面と同じ値の半精度の絵 (線形・1.0 を超える値も残る) を毎フレーム書くようになりました。作品のコードに何も足す必要はありません。繋がっている間だけ書き、繋がっていない間はフレームの仕事は増えません。作品のウィンドウを最小化したり裏に隠したりしても書き続けます。受け手が面を返さなくても作品は止まらず、その間は書かずに見送ります。`mokume watch` では道具が写すので、保存で作品が入れ替わっても受け手は繋ぎ直さずに受け続けます。受け手の数は 4、面は 1 つの受け手につき 2〜8 枚までで、形の合わない頼みは断って 1 行で知らせます ([ADR-0049](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md))。
