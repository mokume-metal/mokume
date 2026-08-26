#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# git 追跡ファイルにバイナリ (画像・動画・音声・モデル・アーカイブ等) が
# 混入していないことを検査する (ADR-0001 原則 7 の機械強制)。
# 例外を認める場合は ALLOWLIST に「パス<TAB>理由」を追記する。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=$(cat <<'EOF'
EOF
)

pattern='\.(png|jpe?g|gif|webp|heic|tiff?|bmp|ico|icns|mp4|mov|avi|webm|mp3|wav|aiff?|m4a|flac|pdf|zip|gz|tar|7z|dmg|obj|fbx|usdz?|gltf|glb|stl|ttf|otf|woff2?|bin|dylib|a|framework)$'

violations=$(git ls-files | grep -iE "$pattern" || true)
if [ -n "$ALLOWLIST" ]; then
  violations=$(comm -23 <(sort <<<"$violations") <(cut -f1 <<<"$ALLOWLIST" | sort))
fi

if [ -n "$violations" ]; then
  echo "バイナリファイルがコミットされている (原則: 生成物・バイナリは git に置かない):" >&2
  echo "$violations" >&2
  echo "画像・動画は外部ホスティングへ上げ URL で参照する。例外は本スクリプトの ALLOWLIST に理由つきで追記する。" >&2
  exit 1
fi
echo "ok: バイナリの混入なし ($(git ls-files | wc -l | tr -d ' ') ファイル検査)"

# (検証用の一時的な変更 — マージしない)
