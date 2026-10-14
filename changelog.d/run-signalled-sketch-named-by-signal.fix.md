<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume run` と `mokume render` で、スケッチが合図で落ちた (`fatalError` の SIGTRAP、SIGSEGV など) とき、`exited with code 5` と表示していたのを、`ended by signal 5 (SIGTRAP)` と表示するように直しました。合図の番号 5 を終了コードのように表示していたので、`exit(5)` で自分から終わったスケッチと見分けられませんでした。

`mokume run` の終了コードも、合図で落ちたスケッチについては、シェルで直に走らせたときの `$?` と同じ `128 + 合図の番号` (SIGTRAP なら 133) になります。これまでは合図の番号そのもの (5) でした。`exit(N)` で終わったスケッチは、これまでどおり N のままです。`mokume render` の終了コードは、これまでどおり 1 です。

`mokume watch` の作り直しの記録 (`build-status` の `status`) も、`swift` が合図で落ちた回は `128 + 合図の番号` で書きます。
