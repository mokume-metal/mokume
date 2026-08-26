#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# .github/workflows/*.yml が YAML として妥当かを検査する。
# 不正な workflow は GitHub 上で「workflow file issue」として黙って失敗し、
# 本来のイベントを取り逃す (#23 の parent-guard で実害が出たクラス)。
# ruby は macOS / ubuntu ランナーの双方に既在のため追加ツール不要。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

status=0
for f in .github/workflows/*.yml; do
  if err=$(ruby -ryaml -e "YAML.load_file('$f')" 2>&1); then
    echo "ok: $f"
  else
    echo "NG: $f は YAML として不正:" >&2
    echo "$err" | head -3 >&2
    status=1
  fi
done
exit $status
