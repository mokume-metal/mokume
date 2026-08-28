# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 追跡ファイルに実行ビットが付いていないことを検査する (#272)。
#
# このリポジトリのスクリプトの呼び口は `bash scripts/x.sh` /
# `python3 scripts/release.py` に一本化されている (Makefile・workflow・
# .claude/settings.json のフックすべて)。`./scripts/x.sh` と直接実行している
# 箇所は 1 つも無い。にもかかわらず実行ビットの有無がファイルごとに割れていると、
# 付いているファイルで一度成功した後、付いていないファイルで初めて
# permission denied を踏む — 原因の分かりにくい失敗だけが残る。
#
# 実行ビットを付ける側に揃えても呼び口は増えないので、外す側に揃える。
# source される library (scripts/guard-lib.sh) や shebang を持たないファイル
# (scripts/check-schemas.sh) もあり、「#! があるなら実行可能に」という規則は
# そもそも成り立たない。
#
# 100644 以外を一律に弾く形にはしない。symlink (120000) や submodule (160000) は
# 実行ビットの話ではなく、この検査が縛る理由が無い。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

entries="$(git ls-files -s)"

# 検査対象が 0 件なら、通っていることに意味が無い (git の出力形式が変わった、
# cd に失敗した等)。緑のまま何も見ていない状態を作らないために落とす
if [ -z "$entries" ]; then
  echo "追跡ファイルが 1 つも見つからない — 検査が成立していない" >&2
  exit 1
fi

# 経路はタブ区切りの 2 列目以降。awk の $4 で取ると空白を含む経路で切れる
violations="$(awk '$1 == "100755"' <<<"$entries" | cut -f2-)"

if [ -n "$violations" ]; then
  echo "実行ビットの付いた追跡ファイルがある (呼び口は bash scripts/x.sh に一本化する):" >&2
  sed 's/^/  /' <<<"$violations" >&2
  echo "" >&2
  # chmod -x だけでは足りない。この検査が見ているのは index のモードで、
  # core.fileMode = false のクローンでは作業ツリーの chmod が index に届かない
  echo "外し方 (index のモードを直接書き換える):" >&2
  echo "  git update-index --chmod=-x $(paste -sd' ' - <<<"$violations")" >&2
  exit 1
fi

echo "ok: 実行ビットの付いた追跡ファイルなし ($(wc -l <<<"$entries" | tr -d ' ') ファイル検査)"
