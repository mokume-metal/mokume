# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check no-binaries reuse-encoding-check reuse-lint github-yaml-lint rulesets-shape hooks-test

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
	@echo "ok: 必要なツールは揃っている"

check: setup

ci-check: no-binaries reuse-encoding-check reuse-lint github-yaml-lint rulesets-shape hooks-test ## per-PR CI と同一の検査 — push 前に通す

no-binaries:
	bash scripts/check-no-binaries.sh

# reuse-lint より先に置く。判定モジュールが壊れていると reuse-lint は「SPDX が
# 無い」としか言わないので、原因を先に見せる
reuse-encoding-check:
	bash scripts/check-reuse-encoding.sh

reuse-lint:
	reuse lint

github-yaml-lint:
	bash scripts/check-github-yaml.sh

# ブランチ保護の定義ファイルの「形」だけを見る (ADR-0006)。実設定との照合には
# 認証が要り、ルールセットは PR と独立に変わるので CI のこの位置には置かない
# (定期実行は #99)。手元では bash scripts/check-rulesets.sh で照合する
rulesets-shape:
	bash scripts/check-rulesets.sh --shape

# エージェント向けフック (署名の強制など) の検査。gh はスタブに差し替わるので
# ネットワークも認証も要らない
hooks-test:
	python3 -m unittest discover -s scripts/tests -p '*_test.py'
