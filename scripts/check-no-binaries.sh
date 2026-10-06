#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# git 追跡ファイル (と、追跡されていないが無視もされていないファイル) に
# バイナリ (画像・動画・音声・モデル・アーカイブ等) が混入していないことを検査する
# (ADR-0001 原則 7 の機械強制)。
# 例外を認める場合は ALLOWLIST に「パス<TAB>理由」を追記する。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=$(cat <<'EOF'
EOF
)

pattern='\.(png|jpe?g|gif|webp|heic|tiff?|bmp|ico|icns|mp4|mov|avi|webm|mp3|wav|aiff?|m4a|flac|pdf|zip|gz|tar|7z|dmg|obj|fbx|usdz?|gltf|glb|stl|ttf|otf|woff2?|bin|dylib|a|framework)$'

# 見るファイルの基準は「git add -A したときに CI の木になるもの」(追跡 + 未追跡 − 無視)。
# 追跡済みだけだと、未追跡の pic.png が手元では緑で、git add して push した後の CI で
# 初めて赤になる (#2015)。**件数と違反の一覧は同じ列挙から出す** (別々に数えるとずれる)。
#   - -z で割る。非 ASCII の名前は C 引用符つきで返り、末尾が " になって拡張子の判定を
#     黙って外れる (緑のままバイナリが入る)
#   - index にだけ残る旧パス (git rm していない削除・改名) は落とす。add -A の後の木に無い。
#     この検査は名前だけを見る (中身は読まない) ので、壊れた symlink は落とさない —
#     add -A なら symlink のままコミットされ、CI の木に入る
files=$(
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' path; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        printf '%s\n' "$path"
      fi
    done
)

violations=$(grep -iE "$pattern" <<<"$files" || true)
if [ -n "$ALLOWLIST" ]; then
  violations=$(comm -23 <(sort <<<"$violations") <(cut -f1 <<<"$ALLOWLIST" | sort))
fi

if [ -n "$violations" ]; then
  echo "バイナリファイルがコミットされている (原則: 生成物・バイナリは git に置かない):" >&2
  echo "$violations" >&2
  echo "画像・動画は外部ホスティングへ上げ URL で参照する。例外は本スクリプトの ALLOWLIST に理由つきで追記する。" >&2
  exit 1
fi
count=0
if [ -n "$files" ]; then
  count=$(wc -l <<<"$files" | tr -d ' ')
fi
echo "ok: バイナリの混入なし ($count ファイル検査)"
