<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->
観測と MCP の observe に time を追加しました。指定した秒で1枚描き直して撮れるため、色などを編集した前後を同じ時刻で比較できます。時刻以外の状態は巻き戻さず、画面と draw の副作用は残ります。単数撮影に限り、外部停止・録画中は理由を返します。応答の appliedTime で適用を確認でき、旧版の作品が指定を無視した場合は MCP が更新を案内します。
