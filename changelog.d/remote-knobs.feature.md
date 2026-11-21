<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run --remote` と `mokume watch --remote` で、スケッチの `@Param` のつまみを同じネットワークのスマホから動かせるようになりました。ターミナル (`watch` では道具のウィンドウにも) に出る QR コードを読むと、スマホのブラウザに宣言どおりのつまみ (範囲のある数・真偽・色・候補) が並びます。スケッチにはポートも新しいコードも要りません。スマホからの変更は窓のつまみと同じ経路で届き、`--record` にも記録されます。`watch` で作り直しても、ページを読み直さずに新しい版のつまみへ切り替わります。ローカルでの簡単なデモやプロトタイプ向けで、`mokume bundle` の `.app` では使えません ([#4126](https://github.com/mokume-metal/mokume/issues/4126))。
