<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`beginRecord("….mov")` で撮っている最中のスケッチを `SIGTERM` や Control + C (`SIGINT`) で止めると、動画が開けないファイルとして残っていたのを直しました。`mokume run` と `mokume watch` はスケッチを `SIGTERM` で止めるので、道具から止めるたびにこれを踏んでいました。スケッチは合図を受けると、撮っていた動画を閉じてから終わります。

`mokume watch` を終えるときは、スケッチが動画を閉じ終えるのを長めに待つようにしました (待っている間はそう名乗ります)。保存のたびの差し替えはこれまでどおり 3 秒で見切るので、そこで閉じきれなかった動画は次の世代が撮り直します。
