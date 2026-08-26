#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# .github/ 配下の YAML が構文として妥当かを検査する。
# 不正な設定は GitHub 上で黙って無効になり、本来の動作を取り逃す —
# workflow なら「workflow file issue」で run が空振りし (#23 の parent-guard で
# 実害が出たクラス)、dependabot なら更新 PR が来なくなる (#87)。どちらも
# 「起きないこと」でしか異常を表現しないため、人が気付くまでが遅い。
#
# 対象は .github/ 配下の *.yml / *.yaml すべて。個別のファイルを名指ししないのは、
# 次に YAML が増えたとき (Issue Form・labeler 等) また同じ穴が空くため。検査漏れが
# 害になる種類の検査なので、包む側に倒す。
#
# 見るのは構文だけで、スキーマは見ない (GitHub 側にスキーマ検査の口が無い)。
# ruby は macOS / ubuntu ランナーの双方に既在のため追加ツール不要。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

status=0
found=0
while IFS= read -r -d '' f; do
  found=1
  # パスは ARGV で渡す。コードに埋め込むと、パスに ' が入ったとき ruby の構文が壊れる
  if err=$(ruby -ryaml -e 'YAML.load_file(ARGV[0])' -- "$f" 2>&1); then
    echo "ok: $f"
  else
    echo "NG: $f は YAML として不正:" >&2
    echo "$err" | head -3 >&2
    status=1
  fi
done < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null | sort -z)

[ "$found" -eq 0 ] && echo "検査対象の YAML が .github/ に無い"
exit $status
