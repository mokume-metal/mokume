# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

# tee を挟んだパイプの失敗を拾うために bash を使う (test ターゲット)
SHELL := /bin/bash

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check build test drawing-evidence render-status shaders schemas api api-list cli-dist reference-shots no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape changelog-lint hooks-test

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
ci-check: build test shaders schemas api no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint rulesets-shape changelog-lint hooks-test drawing-evidence render-status ## per-PR CI と同一の検査 — push 前に通す

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

# changelog.d の断片が、リリースノートに組める形をしているかを見る (#91)。
# **組む側 (release.py) がそのまま検査する** — 別の道具にすると分類の語彙が二重管理に
# なる (ADR-0008 決定 5 段 1)。正典は release.py の SECTIONS で、使える綴りは検査の
# 出力が名指しで教えるので README も綴りを写さない
changelog-lint:
	python3 scripts/release.py lint

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
#
# **Metal の検証レイヤを有効にして走らせる** (#351)。新しい検査を足さず既存の責務を
# 広げる形にしてあるのは、描画の検査が走る場所がここ 1 つだからである (ADR-0008 決定 5)。
# 有効でも所要時間は変わらない (510 件で 21.5 秒 / 21.7 秒・実測)。
#
# **警告は nslog まで上げる** (#357)。上げないと警告は黙って捨てられ、常駐の通し忘れ
# (#351・#357 と 2 度出た) が 1 件も報告されない。上げても、冗長な setRenderPipelineState
# のような助言 (601 件) は記録に出るだけで走り切り、**residency の違反だけが表明で落ちる**
# — 助言まで落とす assert とは違って、これなら常時のゲートにできる。集合そのものを問う
# 検査 (RenderTargetTests・FramePresenterTests) はそのまま置く。どちらが欠けたかが分かる
#
# **CI では有効にしない。** CI の実行環境の GPU はこの世代のコマンド構造に対応して
# おらず、そこでは検証レイヤが「使えるか」の判定 (RenderDevice.isAvailable が試す
# makeMTL4CommandQueue) そのものを表明で落とし、**検査が 1 件も走らないまま止まる**。
# 描画の検査はどのみち CI では 1 本も走らない (ADR-0019 決定 7) ので、検証レイヤが
# 意味を持つのは描画が実際に走る手元だけである
METAL_VALIDATION := $(if $(CI),,MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_WARNING_MODE=nslog)

test:
	@mkdir -p .build
	set -o pipefail; env $(METAL_VALIDATION) swift test 2>&1 | tee .build/test-log.txt

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

# 道具の配布物。**リリースタグを起点に配る** (ADR-0001 原則 6)。ここで束ねたものを
# リリースのワークフローが Release の資産として上げる — CI にステップを足さず、
# 束ね方の実体は Makefile に置く (api-list と同じ形)。
#
# **2 つで 1 組**にする。ひな形は資源の束 (mokume_MokumeCLI.bundle) に入り、実行ファイル
# は Bundle.module としてその束を**隣から**探す。片方だけ配ると、入れた人は new を
# 打った瞬間に「ひな形が見つからない」を踏む。
#
# **実行ファイルは mokume という名前で入れる。** product 名が mokume-cli なのは
# SwiftPM の制約 (ライブラリと同名の product を置けない) で、利用者が打つ名前とは別。
# 案内文は起動された名前から出るので、改名しても印字された行はそのまま打てる。
#
# COPYFILE_DISABLE を立てるのは、macOS の tar が拡張属性を ._ から始まる別ファイルに
# して同梱するため。展開した人の bin に見慣れない物を置かない
CLI_STAGE := .build/dist/stage
CLI_ASSET := .build/dist/mokume-macos-arm64.tar.gz

cli-dist: ## 道具の配布物を束ねる (OUT=path で置き場を指定)
	swift build -c release --product mokume-cli
	rm -rf "$(CLI_STAGE)"
	mkdir -p "$(CLI_STAGE)" "$(dir $(CLI_ASSET))"
	cp .build/release/mokume-cli "$(CLI_STAGE)/mokume"
	cp -R .build/release/mokume_MokumeCLI.bundle "$(CLI_STAGE)/"
	COPYFILE_DISABLE=1 tar -czf "$(or $(OUT),$(CLI_ASSET))" \
		-C "$(CLI_STAGE)" mokume mokume_MokumeCLI.bundle
	@echo "束ねた: $(or $(OUT),$(CLI_ASSET))"

# 参照スケッチの絵。**リポジトリには置かない** — 撮った絵は Gyazo へ上げて URL で
# 参照する。同じフレーム番号を描くので、撮り直せば同じ絵になる
reference-shots: ## 参照スケッチの絵を書き出す (OUT= で置き場を指定)
	swift run reference-sketches --render "$(or $(OUT),shots)"

# ワイヤフォーマットの正典は Schemas/ の JSON Schema で、実装が従う側になる
# (ADR-0018 決定 4)。代表例をスキーマで検証し、正典と例がずれたら落とす
schemas:
	bash scripts/check-schemas.sh
