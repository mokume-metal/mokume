# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check no-binaries reuse-lint workflows-lint hooks-test

setup: ## 開発ツールを確認する
	@command -v reuse >/dev/null 2>&1 || { echo "reuse が見つからない: brew install reuse"; exit 1; }
	@echo "ok: 必要なツールは揃っている"

check: setup

ci-check: no-binaries reuse-lint workflows-lint hooks-test ## per-PR CI と同一の検査 — push 前に通す

no-binaries:
	bash scripts/check-no-binaries.sh

reuse-lint:
	reuse lint

workflows-lint:
	bash scripts/check-workflows-yaml.sh

# エージェント向けフック (署名の強制など) の検査。gh はスタブに差し替わるので
# ネットワークも認証も要らない
hooks-test:
	python3 -m unittest discover -s scripts/tests -p '*_test.py'
