# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

# tee を挟んだパイプの失敗を拾うために bash を使う (test ターゲット)
SHELL := /bin/bash

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check build test drawing-evidence render-status shaders schemas api api-list reference-shots no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape hooks-test

# reuse の encoding 判定モジュールを固定する (#48)。指定が無いと環境にある物が
# 順に選ばれ、charset_normalizer が選ばれた環境だけ日本語の厚いヘッダを持つ
# ファイルの SPDX が丸ごと無視される。chardet は pure Python なので OS にも
# パッケージマネージャにも左右されず、ローカルと CI で同じ結果になる
export REUSE_ENCODING_MODULE := chardet

setup: ## 開発ツールを確認する
	@command -v reuse >/dev/null 2>&1 || { echo "reuse が見つからない: pipx install reuse && pipx inject reuse chardet"; exit 1; }
	@reuse --version >/dev/null 2>&1 || { \
		echo "reuse が $(REUSE_ENCODING_MODULE) を使えない (#48 の回避に必要):"; \
		echo "  pipx install reuse && pipx inject reuse chardet"; \
		echo "Homebrew 版には chardet が同梱されていないため入れ直しが要る"; exit 1; }
	@command -v check-jsonschema >/dev/null 2>&1 || { echo "check-jsonschema が見つからない: pipx install check-jsonschema"; exit 1; }
	@echo "ok: 必要なツールは揃っている"

check: setup

# render-status は**最後**に置く。全部が通ったときだけ「手元で走った」と報告する
# ため (途中で落ちれば make がそこで止まり、報告は行われない)
ci-check: build test shaders schemas api no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape hooks-test drawing-evidence render-status ## per-PR CI と同一の検査 — push 前に通す

no-binaries:
	bash scripts/check-no-binaries.sh

# 上と同じく git index の衛生を見る。呼び口は bash scripts/x.sh に一本化されている
# ので、実行ビットは誰も使っていない — 混ざっていると ./scripts/x.sh を打った人が
# ファイルによって permission denied を踏む (#272)
file-modes:
	bash scripts/check-file-modes.sh

# reuse-lint より先に置く。判定モジュールが壊れていると reuse-lint は「SPDX が
# 無い」としか言わないので、原因を先に見せる
reuse-encoding-check:
	bash scripts/check-reuse-encoding.sh

reuse-lint:
	reuse lint

github-yaml-lint:
	bash scripts/check-github-yaml.sh

# 上の 1 本と役割が違う (#89)。github-yaml-lint は .github/ 配下の YAML すべての構文を
# 名指しせず包み (#87)、こちらは workflows の意味 — 式・イベント名・run: のシェル — を
# 見る。workflows で構文が二重に見られるのは「包む」設計の副産物で、除外を書けば名指しに
# 戻り、次に YAML が増えたとき同じ穴が空く (ADR-0008 決定 5 の「重ねる理由」)
workflows-lint:
	bash scripts/check-workflows.sh

# ブランチ保護の定義ファイルの「形」だけを見る (ADR-0006)。実設定との照合には
# 認証が要り、ルールセットは PR と独立に変わるので CI のこの位置には置かない
# (定期実行は #99)。手元では bash scripts/check-rulesets.sh で照合する
rulesets-shape:
	bash scripts/check-rulesets.sh --shape

# エージェント向けフック (署名の強制など) の検査。gh はスタブに差し替わるので
# ネットワークも認証も要らない
hooks-test:
	python3 -m unittest discover -s scripts/tests -p '*_test.py'

# ライブラリのビルドとテスト。ツールチェーンの要求は ADR-0009 が定める
# (macOS 26 / Xcode 26 / Swift 6 言語モード)。満たさない環境ではここで落ちる
build:
	swift build

# テストの記録を残す。何が走って何がスキップされたかを、手元の実行の報告
# (local-render・#304) が読む
test:
	@mkdir -p .build
	set -o pipefail; swift test 2>&1 | tee .build/test-log.txt

# 描画に触れる PR に絵が載っているかを見る (#306)。**絵が正しいことは見ない** —
# 用意されていることだけを見る。判定には PR が要るので、まだ PR が無いブランチでは
# 理由を述べて 0 で抜ける (PR を出した後の実行から効くようになる)
drawing-evidence:
	bash scripts/check-drawing-evidence.sh

# 描画の検査が走ったことを commit status として報告する (#304)。CI から呼ばれても
# 認証が無いので何もしない。報告しない理由を述べて必ず 0 で終える
render-status:
	bash scripts/render-status.sh local

# シェーダの原文はビルドに含まれない (SwiftPM は .metal を運ぶだけ) ので、誤りは
# 実行するまで分からない。描画を要する検査は実行環境の制約で CI では走らない (#180)
# ため、ここで組み立てて落とす
shaders:
	bash scripts/check-shaders.sh

# 公開 API の面。**一覧はリポジトリへ置かない** — 置くと「それが古くないことを守る
# 検査」が要るようになり、以後すべての変更がその検査に引っかかる (ADR-0001 原則 8)。
# 要るときに組み立てれば、そのクラスの検査ごと不要になる。
#
# 置き場を分けるのは、シンボルグラフを出す指定が普段のビルドと食い違うため。同じ
# 置き場を使うと build / test と api が互いを作り直させ続ける
API_GRAPHS := .build/api/symbol-graphs
API_BUILD := swift build --scratch-path .build/api \
	-Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc $(API_GRAPHS)

api: ## 公開 API が名前と面の規範 (ADR-0020) に沿っているかを検査する
	$(API_BUILD)
	python3 scripts/api-surface.py check --graphs $(API_GRAPHS)

api-list: ## 公開 API の一覧を組み立てる (OUT=path VERSION=v0.0.0)
	$(API_BUILD)
	python3 scripts/api-surface.py list --graphs $(API_GRAPHS) \
		--version "$(or $(VERSION),(開発版))" $(if $(OUT),--output "$(OUT)",)

# 参照スケッチの絵。**リポジトリには置かない** — 撮った絵は Gyazo へ上げて URL で
# 参照する。同じフレーム番号を描くので、撮り直せば同じ絵になる
reference-shots: ## 参照スケッチの絵を書き出す (OUT= で置き場を指定)
	swift run reference-sketches --render "$(or $(OUT),shots)"

# ワイヤフォーマットの正典は Schemas/ の JSON Schema で、実装が従う側になる
# (ADR-0018 決定 4)。代表例をスキーマで検証し、正典と例がずれたら落とす
schemas:
	bash scripts/check-schemas.sh
