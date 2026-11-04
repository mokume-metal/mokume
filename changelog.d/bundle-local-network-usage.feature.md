<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume bundle` が、ローカルネットワークの許可を求めるダイアログの説明文を `.app` へ入れるようにしました。`mokume-app.json` に `localNetworkUsage` を書くと、`Info.plist` の `NSLocalNetworkUsageDescription` になります。OSC や UDP で同じネットワークの別の機械へ送る作品は、束ねた `.app` ではこの許可が要ります (受信には要りません)。カメラ・マイクと違い、書かなくてもダイアログは出るので、無いことで `mokume bundle` は止まりません。送りが塞がれたときの見え方と許可の見る場所は、利用ガイドの「アプリとして配布する」に書きました。
