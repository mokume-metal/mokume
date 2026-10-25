<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` の作り直しで、新しい版が最初の絵を出す前に失敗で終わったとき、前の版を残して走らせ続けるようにした。これまでは「走っていた子が自分で消えた」と読み、前の版も畳んで、絵が 1 枚も無い窓だけが残っていた。端末は、作り直しが通らなかった回と同じ言葉 (`still running the version from before` / `nothing is running yet`) で言い、`.mokume/build/status.json` は `ok: true`・`launched: false`・`notStartedReason` で起動できなかった回を書く。終了コード 0 で終わった子は、起動の失敗とは名乗らない。
