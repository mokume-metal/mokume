# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check no-binaries

setup: ## 開発ツールを確認する
	@echo "ok: 現時点で追加ツールは不要"

check: setup

ci-check: no-binaries ## per-PR CI と同一の検査 — push 前に通す

no-binaries:
	bash scripts/check-no-binaries.sh
