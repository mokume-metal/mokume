# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check build test shaders schemas no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape hooks-test

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

ci-check: build test shaders schemas no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape hooks-test ## per-PR CI と同一の検査 — push 前に通す

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

test:
	swift test

# シェーダの原文はビルドに含まれない (SwiftPM は .metal を運ぶだけ) ので、誤りは
# 実行するまで分からない。描画を要する検査は実行環境の制約で CI では走らない (#180)
# ため、ここで組み立てて落とす
shaders:
	bash scripts/check-shaders.sh

# ワイヤフォーマットの正典は Schemas/ の JSON Schema で、実装が従う側になる
# (ADR-0018 決定 4)。代表例をスキーマで検証し、正典と例がずれたら落とす
schemas:
	bash scripts/check-schemas.sh
