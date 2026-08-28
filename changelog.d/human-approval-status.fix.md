<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

承認したのに PR が永久にマージできなくなる詰みを直した。承認待ちを表す `human-approval` を check run から commit status へ移し、待ちは `pending` (保留中) で表す。check run は最初に作った run の check suite に居続けるため、後から届く承認が最新の suite に現れず、API は `success` と答えるのに画面は「報告待ち」のまま止まっていた。commit status には suite が無く、同じ context の最新が常に勝つ。
