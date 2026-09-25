# mokume 開発コマンド。検査の入口は ci-check の 1 つ — CI はこれを呼ぶだけにする
# (ローカルと CI の乖離を構造的に不可能にする。ADR-0001 原則 8)。

# tee を挟んだパイプの失敗を拾うために bash を使う (test ターゲット)
SHELL := /bin/bash

.DEFAULT_GOAL := ci-check
.PHONY: setup check ci-check build test test-release examples drawing-evidence render-status catch-up entry-check shaders params schemas api tool-language isolated-deinit api-list reference example-shots example-shots-check cli-dist reference-shots no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint publish-trigger rulesets-shape changelog-lint docs-links adrs agents-md-size hooks-test

# **並行では走らせない** (#784)。的の並びには意味があり、-j を付けると壊れる
# — render-status を最後に置いているのは「全部が通ったときだけ手元の実行を報告する」
# ためで (下記)、並行に走れば落ちた検査があっても報告が出うる。swift の置き場
# (.build/.lock) の取り合いも同時に避けられる。ci-check は駆動役が 1 段ずつ make を
# 起こすので並びは構造的に守られるが (#1182)、段を手で並べて打つ場合はこれが守る
.NOTPARALLEL:

# reuse の encoding 判定モジュールを固定する (#48)。指定が無いと環境にある物が
# 順に選ばれ、charset_normalizer が選ばれた環境だけ日本語の厚いヘッダを持つ
# ファイルの SPDX が丸ごと無視される。chardet は pure Python なので OS にも
# パッケージマネージャにも左右されず、ローカルと CI で同じ結果になる
export REUSE_ENCODING_MODULE := chardet

setup: ## 開発ツールを確認する
	@command -v python3 >/dev/null 2>&1 || { echo "python3 が見つからない: xcode-select --install"; exit 1; }
	@for cmd in gh jq openssl; do \
		command -v $$cmd >/dev/null 2>&1 || { echo "$$cmd が見つからない: brew install $$cmd"; exit 1; }; \
	done
	@command -v reuse >/dev/null 2>&1 || { echo "reuse が見つからない: pipx install reuse && pipx inject reuse chardet"; exit 1; }
	@reuse --version >/dev/null 2>&1 || { \
		echo "reuse が $(REUSE_ENCODING_MODULE) を使えない (#48 の回避に必要):"; \
		echo "  pipx install reuse && pipx inject reuse chardet"; \
		echo "Homebrew 版には chardet が同梱されていないため入れ直しが要る"; exit 1; }
	@command -v check-jsonschema >/dev/null 2>&1 || { echo "check-jsonschema が見つからない: pipx install check-jsonschema"; exit 1; }
	@echo "ok: 必要なツールは揃っている"

check: setup

# ci-check が走らせる段の並び。render-status は**最後**に置く。全部が通ったときだけ
# 「手元で走った」と報告するため (途中で落ちればそこで止まり、報告は行われない)
#
# **この並びは「CI と同一」から 2 つだけ意図的にずれている。** drawing-evidence と
# render-status は CI では必ず no-op になる — ci-check のジョブへ GH_TOKEN を持ち込まない
# 設計 (.github/workflows/ci.yml の drawing-evidence ジョブの冒頭) のため両者が理由を
# 述べて 0 で抜け、本物の判定は同じファイルの独立したジョブ (drawing-evidence /
# render-signal) が持つ。ここに置いてあるのは手元のためである
CI_CHECK_STEPS := build test examples shaders params schemas api tool-language isolated-deinit reference entry-check example-shots-check no-binaries file-modes reuse-encoding-check reuse-lint github-yaml-lint workflows-lint publish-trigger rulesets-shape changelog-lint docs-links adrs agents-md-size hooks-test drawing-evidence render-status

# 段を prerequisite に並べず、駆動役に 1 つずつ走らせる (#1182)。数分かかる間に
# いまどの段に居てあとどれくらいかを名乗らせるためで、落ちたらそこで止まる性質と、
# 段ごとに build を組み直さないこと (-o build) は駆動役が持つ (scripts/ci-check.sh の冒頭)
ci-check: ## per-PR CI と同一の検査 — push 前に通す
	@MAKE='$(MAKE)' bash scripts/ci-check.sh $(CI_CHECK_STEPS)

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

# 公開の起動条件が、面の入力を覆っているかを見る (#478)。**絞りと入力を突き合わせる
# のではなく、絞りを持たせない**ことを検査する — 突き合わせる形にすると入力の一覧という
# 2 つ目の写しが要る。上の 2 本とは見ているものが違う (構文でも actionlint の意味でもなく、
# 公開が取り逃す入力があるか) ので重ねる
publish-trigger:
	python3 scripts/check-publish-trigger.py

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

# ドキュメントの相対リンクと見出しアンカーが指し先を持っているかを見る (#90)。
# **外部 URL は見ない** — ネットワーク依存と flaky を CI に持ち込まないため。
#
# changelog.d の断片には changelog-lint が「リンクは絶対 URL のみ」を課しており、
# 対象が重なる。重ねる理由は見ているものが違うこと — あちらはリリースノートに
# 載った時点で壊れる書き方を断つ制約で、docs 本体の相対リンクは誰も見ていない
# (ADR-0008 決定 5)。断片を除外リストで外す形は採らない。除外を書けば検査は
# 名指しに戻り、次に .md が増えたとき同じ穴が空く
docs-links:
	python3 scripts/check-docs-links.py

# エージェント向けフック (署名の強制など) の検査。gh はスタブに差し替わるので
# ネットワークも認証も要らない
# ADR の形を見る。連番が一意であること (#500) と、状態欄が本文の改訂に追随して
# いること (#545)。**docs-links とは見ているものが違う** — あちらの責務は
# 「指し先の不在」で、番号が重複していてもファイル名が別なら全リンクが解決する。
# 実際 #490 と #491 が両方 0026 を取ったとき docs-links は緑のまま通った
# (ADR-0008 決定 5 の段 1 を検討した結果、責務を広げずに 1 本足している)。
# 状態欄のほうは逆に、既にある ADR の検査へ責務を寄せている (段 1)
#
# **番号の重複に効くのは merge queue の層である。** PR 単体では相手の枝が見えない
# ので、並走した 2 本目が赤くなるのは合流後の姿を検査するとき — CI は merge_group
# でもこれを呼ぶ
adrs:
	bash scripts/check-adrs.sh

# AGENTS.md の分量をラチェット + 節ごとの上限で持つ (#737)。理由は検査スクリプトの冒頭
agents-md-size:
	python3 scripts/check-agents-md-size.py

hooks-test:
	python3 -m unittest discover -s scripts/tests -p '*_test.py'

# 公開 API の面 (api) と参照の面 (reference) が読む材料。**普段のビルドに出させ、
# 置き場は 1 本に保つ** (#784)。
#
# かつては「シンボルグラフを出す指定が普段のビルドと食い違う」ことを避けて scratch path
# ごと分けていたが (build は .build / api は .build/api)、その代償が clean な runner での
# **パッケージのフルコンパイル 2 回**だった (手元の実測で 2 本目に 20 秒)。食い違いは
# **build と test の両方へ同じ指定を渡せば消える** ので、置き場を分ける理由も消える。
# 出させたことによる増分は測定誤差に埋まる (clean build で 19 秒 → 18 秒・手元の実測)。
#
# **テストのモジュールのグラフも同じ置き場に並ぶ。** swift test にも同じ指定が要るため
# (渡さないとそこで作り直しが起きて、分けていた頃と同じ二重コンパイルに戻る)。
# scripts/api-surface.py の own_modules() は置き場のファイル名から「自前のモジュール」を
# 読むので集合はそのぶん広がるが、**ライブラリの公開署名にテストの型は出られない**
# (依存の向きが逆) ので判定は動かない — 一覧も検査も分けていた頃と 1 記号も違わないことを
# 実測した。参照の面のほうは reference-graphs.py が --module で名指しするので無関係
#
# **置き場は絶対パスで渡す** ([#1291])。Xcode 27 (Swift 6.4) の SwiftPM は、相対パスを
# 渡されるとグラフを 1 本も出さない — **成功で返り、警告も出ず、どこにも書かれない**。
# 迷子になっているのではないことは、scratch path の下を浚って 0 件だったことで確かめた。
# 26 では相対でも出ていたので、解決の基準 (cwd) が 27 で変わったと読めるが、そこまでは
# 追っていない (上流への報告はこの Makefile の仕事ではない)。
#
# 出ないこと自体は api-surface.py が既に見ているので、新しい見張りは足さない。あちらの
# diagnose_empty() は置き場を読んで、**置き場が無いのか / 1 本も出ていないのか / 名指しした
# モジュールが無いのか / 出ているが公開シンボルが 0 個なのか**を名乗って落ちる ([#1308])。
#
# [#1291]: https://github.com/mokume-metal/mokume/issues/1291
# [#1308]: https://github.com/mokume-metal/mokume/issues/1308
SYMBOL_GRAPHS := $(CURDIR)/.build/symbol-graphs
SYMBOL_GRAPH_FLAGS := -Xswiftc -emit-symbol-graph \
	-Xswiftc -emit-symbol-graph-dir -Xswiftc $(SYMBOL_GRAPHS)

# ライブラリのビルドとテスト。ツールチェーンの要求は ADR-0009 が定める
# (macOS 26 / Xcode 26 / Swift 6 言語モード)。満たさない環境ではここで落ちる
build:
	swift build $(SYMBOL_GRAPH_FLAGS)

# テストの記録を残す。何が走って何がスキップされたかを、手元の実行の報告
# (local-render・#304) が読む。**この節は下の 2 つの入口 — debug の test と release の
# test-release — の両方に掛かる** (#1089)。
#
# **正本は console ではなく `--xunit-output` の XML である** (#1056)。swift-testing の
# console 出力は実行ごとに数十〜数百行を落とす — 全件が緑で make が 0 を返しているのに
# `◇ started` / `✔ passed` / `✔ Suite passed` / 最終要約 / `✘ failed after` が記録に無い、
# という状態が起きる。落ちる集合は実行ごとに別物で、管を外しても Metal の nslog を切っても
# 止まらない (書き先にも同居する出力にも依らない、上流の挙動)。SwiftPM が自分でファイルへ
# 書く XML は同じ実行で全件を持っていたので、判定はそちらから読む。
# `tee` の記録は残す — 人が実行中に読む先で、正本でなくなるだけである。
#
# **release の記録は別のファイルへ書く** (#1089)。同じ置き場へ書くと、`local-render` の
# 判定が読む記録 (render-status.sh の RENDER_TEST_RECORD = 下の TEST_RECORD) を release の
# 実行が上書きしうる — `make ci-check && make test-release` は計測のとき普通に起きる並びで、
# そのとき**「手元で全検査が通った」の意味が変わる** (ci-check は debug で回るのに、報告が
# 読む記録は release のものになる)。2 つとも要るのは、**release でしか走らない検査がある**
# からである (ShapeTests の `.enabled(if: !isDebugBuild)`)。
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

# 記録の綴りは render-status.sh の RENDER_TEST_RECORD と揃える。SwiftPM は渡した名前の
# 末尾に検査ライブラリの名前を挟むので、こちらが渡すのは接尾辞の付く前の名前である
TEST_RECORD_BASE := .build/test-results.xml
TEST_RECORD := .build/test-results-swift-testing.xml

# release の記録。debug と別のファイルになる名前を渡す (理由は上の「別のファイルへ書く」
# の段)。接尾辞の挟まり方は debug と同じで、SwiftPM が -swift-testing を足す
TEST_RECORD_RELEASE_BASE := .build/test-results-release.xml
TEST_RECORD_RELEASE := .build/test-results-release-swift-testing.xml

# **検査のプロセスが要約を残さずに消えた回は、そう名乗って材料を残す** (#1526)。
# 本体の検査のプロセス (swiftpm-testing-helper) が要約も記録も残さずに消え、出るのが
# 「test で止まった」だけの回が 3 度あった。上の出力に失敗は無く、打ち直すと tee が
# test-log.txt を切り詰め、上の rm -f が記録を消すので、原因 (#1527) を調べる材料が
# 1 つも残らなかった。swift test が非 0 で終わった回に scripts/test-vanished.sh が記録を
# 読み、無い / 読めない / 失敗を 1 件も持たない回だけを名乗って、材料を
# .build/test-vanished/ の下へ残す。**判定に console は使わない** — 上の「正本は console
# ではなく」のとおり要約は緑の回でも落ちるので、「要約が無い」を印にすると緑の回でも
# 名乗る (#1056)。段の終了コードは swift test のものをそのまま返す。
#
# ビルドと実行を分けるのは、ビルドで止まった回を「消えた」と名乗らないためである。
# どちらも記録が無いまま非 0 で終わるので、記録からは見分けられない。印
# (.build/test-started) は段の始まりで、材料の jetsam の行と報告の「この間にできた」の
# 境目に使う
test:
	@mkdir -p .build
	@rm -f $(TEST_RECORD)
	@touch .build/test-started
	set -o pipefail; swift build --build-tests $(SYMBOL_GRAPH_FLAGS) 2>&1 | tee .build/test-log.txt
	set -o pipefail; env $(METAL_VALIDATION) swift test --skip-build --xunit-output $(TEST_RECORD_BASE) 2>&1 | tee -a .build/test-log.txt \
		|| { code=$$?; bash scripts/test-vanished.sh $$code $(TEST_RECORD) .build/test-log.txt .build/test-started; exit $$code; }
	@test -s $(TEST_RECORD) || { \
		echo "記録が出来ていない ($(TEST_RECORD))。SwiftPM が --xunit-output の綴りを"; \
		echo "変えた可能性がある — render-status.sh の RENDER_TEST_RECORD と併せて直す"; \
		exit 1; }

# release でテストを回す — 性能を測るための器 (#761)。**ci-check には入れない** (計測の
# ためだけで、常時のゲートに要る検査は debug の test が全部持つ)。
#
# `-enable-testing` を渡すのは、SwiftPM が release では testability を有効にしないため
# (`@testable import` が `not compiled for testing` で落ちる)。Metal の検証レイヤは
# 載せない — 計測の器なので、検証レイヤの費用で時間を歪ませない
#
# **記録は残す** (#1089)。release でしか走らない検査が落ちたとき、端末の出力からは名前を
# 取り逃す — 落ちる集合が実行ごとに別物だからである (上の「正本は console ではなく」の段)。
# `tee` は付けない。debug の tee は「人が実行中に読む先」で、こちらは計測のときに端末を
# 見ながら打つ器なので、同じものが 2 つ要らない
test-release: ## release でテストを回す (性能の計測用。ci-check には含まれない)
	@mkdir -p .build
	@rm -f $(TEST_RECORD_RELEASE)
	swift test -c release -Xswiftc -enable-testing --xunit-output $(TEST_RECORD_RELEASE_BASE)
	@test -s $(TEST_RECORD_RELEASE) || { \
		echo "記録が出来ていない ($(TEST_RECORD_RELEASE))。SwiftPM が --xunit-output の"; \
		echo "綴りを変えた可能性がある — debug 側の TEST_RECORD と併せて直す"; \
		exit 1; }

# 描画に触れる PR に絵が載っているかを見る (#306)。**絵が正しいことは見ない** —
# 用意されていることだけを見る。判定には PR が要るので、まだ PR が無いブランチでは
# 理由を述べて 0 で抜ける (PR を出した後の実行から効くようになる)
drawing-evidence:
	bash scripts/check-drawing-evidence.sh

# 描画の検査が走ったことを commit status として報告する (#304)。CI から呼ばれても
# 認証が無いので何もしない。報告しない理由を述べて必ず 0 で終える
render-status:
	bash scripts/render-status.sh local

# merge queue から弾かれた描画 PR を queue へ戻す (#457)。取り込み → 検査 → push →
# 報告 → 戻す の 5 手を 1 手にする。**打つ意味が無いときは走らない** (描画に触れない
# PR・先に描画 PR が居る場合) ので、順番待ちの数分を無駄にしない
#
# **3 (打つ意味が無い = 待つのが正解) はここで成功に均す** (#786)。スクリプトは 3 と 1 を
# 分けて返す契約を持つが、その区別を要るのは終了コードを読む呼び手だけで、`make catch-up`
# を打つ人が受け取るのは赤いエラーか否かの 1 ビットである。素で呼ぶと「先に描画 PR が
# 居るので待て」という正常な結果が `Error 3` として出て、**このスクリプトが最も避けたかった
# 取り違えが、いちばん使われる入口で起きる**。契約は他の呼び手のために保ち、「3 は成功
# として扱う」の表明はこちらに置く。1 (途中で止まった) は従来どおり赤くする
#
# **3 以外は、スクリプトの終了コードをそのまま返して名乗る** (#867)。`|| [ $? -eq 3 ]` で
# 済ませていた頃は 3 以外が全部 `Error 1` に潰れ、止まったときに何で止まったのか
# (1 = 途中で止まった / 64 = 使い方の誤り / それ以外 = 中で叩いた何かの失敗) を読めなかった。
# 起票者が出力から「exit 2」と読み違えたのもこれが原因である
# **PR=<番号> を渡すと代打ちになる** (#967)。持ち主のセッションが居ない描画 PR を、
# origin/<相手の枝> から切った木で覆い直せる (作り方は scripts/catch-up.sh の冒頭)
catch-up: ## 弾かれた描画 PR を、合流後の姿を覆い直して merge queue へ戻す (PR=<番号> で代打ち)
	bash scripts/catch-up.sh $(if $(PR),--pr $(PR)) || { code=$$?; [ $$code -eq 3 ] && exit 0; \
	  echo "catch-up: scripts/catch-up.sh が終了コード $$code で止まった" >&2; exit $$code; }

# 説明文の中の例が、実際にコンパイルできるかを見る (#479)。腐った例は説明が無いより
# 悪い — 読者はそれを写して、通らない理由を自分の側に探す。
#
# **組み直さない。** build が作った成果物へ直接当てるので、パッケージを 2 つ目に作って
# CI の時間を倍にしなくて済む。その代わり build の後でなければ走らない (的が依存を持つ)。
#
# **撮る側 (example-shots) とは見ているものが違う。** あちらは囲みが付いた例を撮って
# 書き戻す仕組みで、GPU と鍵が要るので手元でしか走らない。こちらは囲みの有無によらず
# 全部の例を組み立てる。包み方だけは scripts/example_wrapping.py に 1 つ置いて共有する
# — 別々に包むと、撮れる例と組める例が食い違う (ADR-0001 原則 9)
examples: build ## 説明文の中の例が組めるかを見る
	python3 scripts/check-examples.py

# 入口が面として成立しているかを見る (#482)。**組み立ての的は無い** — 手で書く層は
# make reference が Documentation/site/. ごと被せるので、ここは中身だけを見る
entry-check:
	python3 scripts/check-entry.py Documentation/site --catalog "$(REFERENCE_CATALOG)"

# シェーダの原文はビルドに含まれない (SwiftPM は .metal を運ぶだけ) ので、誤りは
# 実行するまで分からない。描画を要する検査は実行環境の制約で CI では走らない (#180)
# ため、ここで組み立てて落とす
shaders:
	bash scripts/check-shaders.sh

# つまみの宣言の書き間違い (名前の重なり・型の書き忘れ) は「ビルドで止まる」約束
# なので、止まることは実行しては確かめられない (ADR-0030 決定 5)。組み上げ済みの
# モジュールに対して型検査を通し、通るものと止まるものを見る。**テストの中で
# package を組み直さない** — 時間の上限を持つ他の検査と CPU を奪い合う。
#
# **組み上げ済みを prerequisite で要求する** (examples と同じ形・#784)。スクリプト側の
# 実行時チェックは残す — あちらは単体で打った人へ「次にすること」を言う案内である
params: build
	bash scripts/check-param-declarations.sh

# 公開 API の面。**一覧はリポジトリへ置かない** — 置くと「それが古くないことを守る
# 検査」が要るようになり、以後すべての変更がその検査に引っかかる (ADR-0001 原則 8)。
# 要るときに組み立てれば、そのクラスの検査ごと不要になる。
#
# **組み直さない。** build が出したシンボルグラフをそのまま読む (examples と同じ形)。
# 材料の出どころと、置き場を 1 本にした理由は SYMBOL_GRAPHS の宣言にある
api: build ## 公開 API が名前と面の規範 (ADR-0020) に沿っているかを検査する
	python3 scripts/api-surface.py check --graphs $(SYMBOL_GRAPHS)

# 道具が話す言葉は英語 (ADR-0038 決定 1)。Sources/ の Swift でコメントの外に日本語が無いかを見る。
# 組み上げは要らない — 字句だけを読む (#1160)
tool-language: ## Sources/ の Swift でコメントの外に日本語を置いていないかを検査する
	python3 scripts/check-tool-language.py

# `isolated deinit` が隔離を明示した型の中にあるかを見る (#1083)。明示が無いと
# `make test-release` がコンパイルできなくなるのに、debug も `swift build -c release`
# (製品) も通る — **足した本人には壊れて見えない**形で 2 度起きた (#761 → #1021)。
#
# **段 1 を採っている** (ADR-0008 決定 5)。本物の判定はコンパイラで、それには release の
# テストビルドを CI で回すしかないが (段 2)、その入口は #1096 が持つ。ここが引き受けるのは
# **赤が理由の正典まで案内すること**である — 再発の経路は「散文で書いた作法が読まれなかった」
# 1 本なので、コンパイラの診断 (正典を指さない) では 3 度目を止められない。
#
# 組み上げは要らない — 字句だけを読む (tool-language と同じ形)
isolated-deinit: ## Sources/ の isolated deinit が隔離を明示した型の中にあるかを検査する
	python3 scripts/check-isolated-deinit.py

api-list: build ## 公開 API の一覧を組み立てる (OUT=path VERSION=v0.0.0)
	python3 scripts/api-surface.py list --graphs $(SYMBOL_GRAPHS) \
		--version "$(or $(VERSION),(開発版))" $(if $(OUT),--output "$(OUT)",)

# 参照の面 (人が読む API の面)。**説明文 (`///`) が唯一の入力**で、面はその生成物
# (ADR-0027 決定 1)。リポジトリには置かず、公開のワークフローがここを呼んで配る。
#
# **`reference-shots` とは別物** — あちらは参照スケッチ (Sketches/) が描く絵で、
# こちらは説明文から組み立てる読む面である。
#
# **面に出すモジュールは名指しする。** 渡した置き場にあるシンボルグラフのモジュールは
# 区別されず全部ページになるので、選り分けないと product に含まれない開発用の実行
# ターゲット (reference-sketches・frame-rate-probe) まで公開される。一覧の側
# (api-surface.py の --module) と同じ名指しをここでも要求する (ADR-0027 決定 1)。
#
# **面が名乗る名前も名指しする** (#561)。面の URL とページのモジュール表示はシンボル
# グラフの module.name が決めるので、何もしなければそこに入るのはターゲット名 —
# ADR-0016 の層の割り方の産物であって、面の名前として選んだものではない。名前を
# 差し替える理由と、アンブレラのグラフをそのまま渡せない実測は scripts/reference-graphs.py
# の冒頭にある。
#
# **手で書く層は Documentation/site/ を丸ごと被せる** (ADR-0027 決定 3)。どちら側でも
# 選り分けをしないので、公開へ写す資産の列挙が現れない — 列挙は漏れ、漏れたときの症状は
# 「そのファイルだけが公開されない」でビルドは緑のままである。
#
# **警告は落とす** (#479)。docc の警告はほぼ全部が「読者が踏むリンク切れ」で、変換は
# 成功したまま面に出る。カタログの `.md` の題より前に何かを置いて**ページの説明と
# Topics が丸ごと落ちた**ときも、出るのは警告 1 本だけだった (#478 で踏んだ)。
# 新しい検査を足さずに道具の口で済ませている (ADR-0008 決定 5 段 2)。
#
# 組み立ての後に、置いたものが本当に出ているかを自分で確かめる — この道具のいちばん
# 多い壊れ方は「変換は成功し、警告も出ず、出力にだけ存在しない」である。
REFERENCE_CATALOG := Documentation/mokume.docc
REFERENCE_MODULES := MokumeCore
# 面が名乗る名前。**ターゲット名ではなく、利用者が import する名前で名乗る**
REFERENCE_SURFACE := mokume
REFERENCE_GRAPHS := .build/reference-graphs
REFERENCE_OUT := .build/reference
# 面から外す型。**面の相手はスケッチを書く人 1 種類**で、道具・エージェント・実行の
# 土台だけが触るものは人が名指しして外す (ADR-0027 決定 5 が 1 本ずつ理由を持つ)。
# public は 1 つも動かないので、一覧も ADR-0020 の検査も全部を見たままになる
REFERENCE_OMIT := \
	SketchApplication SharedFrameWindow SharedFramePreview SketchRuntime Clock FrameRateNotice OutputStage \
	StartupReads WorkDirectory SourceStamp RuntimeLoad BundledShaders \
	InputState InputEvent \
	ObservationRequest ObservationReport ExposedValue FrameStats \
	ParamBox

reference: build ## 参照の面を組み立てる (OUT= 置き場 / BASE= 公開時の基準パス)
	rm -rf "$(REFERENCE_GRAPHS)" "$(or $(OUT),$(REFERENCE_OUT))"
	mkdir -p "$$(dirname "$(or $(OUT),$(REFERENCE_OUT))")"
	python3 scripts/reference-graphs.py \
		--graphs "$(SYMBOL_GRAPHS)" --out "$(REFERENCE_GRAPHS)" \
		--surface "$(REFERENCE_SURFACE)" --module $(REFERENCE_MODULES) \
		--omit $(REFERENCE_OMIT)
	xcrun docc convert "$(REFERENCE_CATALOG)" \
		--additional-symbol-graph-dir "$(REFERENCE_GRAPHS)" \
		--fallback-bundle-identifier org.mokume.reference \
		--transform-for-static-hosting \
		--warnings-as-errors \
		$(if $(BASE),--hosting-base-path "$(BASE)",) \
		--output-path "$(or $(OUT),$(REFERENCE_OUT))"
	cp -R Documentation/site/. "$(or $(OUT),$(REFERENCE_OUT))/"
	python3 scripts/check-published-reference.py \
		"$(or $(OUT),$(REFERENCE_OUT))" --catalog "$(REFERENCE_CATALOG)"

# 道具の配布物。**リリースタグを起点に配る** (ADR-0001 原則 6)。ここで束ねたものを
# リリースのワークフローが Release の資産として上げる — CI にステップを足さず、
# 束ね方の実体は Makefile に置く (api-list と同じ形)。
#
# **実行ファイルと、道具立てが作った資源の束を全部**入れる。束は実行ファイルの**隣から**
# 探されるので (Bundle.module)、1 つでも欠けるとその資源を読む経路だけが配った先で落ちる。
#
# **名前を直書きしない。** ここが mokume_MokumeCLI.bundle だけを挙げていたために、
# MokumeCore の束が v0.5.0 から 3 版にわたって欠け、v0.6.0 で窓の所有が道具側へ移った
# 途端に watch が起動できなくなった (#1054)。入れるものの正典は Package.swift の宣言で、
# 道具立てはそこから束を作る — その成果物をそのまま全部入れれば、資源が増えても
# ここを touch せずに追随する (ADR-0029 決定 4)。
#
# **欠落は、配る前に分かる形にする** (同決定)。束ねた後に資産の中身と突き合わせ、作られた
# 束が 1 つでも入っていなければ赤で止まる。束ねる手と確かめる手は同じ 1 つの列挙を読む。
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
	@set -eu; \
	bundles="$$(cd .build/release && ls -d *.bundle 2>/dev/null || true)"; \
	if [ -z "$$bundles" ]; then \
		echo "道具立てが資源の束を 1 つも作っていない (.build/release に *.bundle が無い)" >&2; \
		exit 1; \
	fi; \
	for bundle in $$bundles; do cp -R ".build/release/$$bundle" "$(CLI_STAGE)/"; done; \
	asset="$(or $(OUT),$(CLI_ASSET))"; \
	COPYFILE_DISABLE=1 tar -czf "$$asset" -C "$(CLI_STAGE)" mokume $$bundles; \
	listed="$$(tar tzf "$$asset")"; \
	for bundle in $$bundles; do \
		printf '%s\n' "$$listed" | grep -q "^$$bundle/" || { \
			echo "束ねたはずの $$bundle が資産に入っていない: $$asset" >&2; exit 1; }; \
	done; \
	echo "束ねた: $$asset"; \
	echo "入れた束: $$(echo $$bundles | tr '\n' ' ')"

# 説明文の中の例の絵。**人が貼るのではなく、コードから機械が撮って書き戻す**
# (ADR-0027 決定 2)。`///` の中の ```swift の塊に囲み (<!-- shot: … -->) を付けると
# 対象になり、囲みの中だけが機械の領域になる。
#
# **`reference-shots` とは別物** — あちらは参照スケッチ (Sketches/) が描く絵、
# こちらは説明文の中の例の絵である。
#
# **撮るのは手元だけ。** GPU と外部サービスの鍵が要るので CI では走らない
# (描画の検査が CI で 1 本も走らないのと同じ理由・ADR-0019 決定 7)。CI が見るのは
# 下の -check で、こちらはソースを読むだけなので GPU も鍵も要らない。
example-shots: ## 説明文の中の例を撮って書き戻す (OUT= 置き場)
	python3 scripts/example-shots.py --capture \
		--token-command "$${MOKUME_GYAZO_TOKEN_CMD:?Gyazo のトークンを標準出力に出すコマンドを渡す}" \
		$(if $(OUT),--render "$(OUT)",)

# 囲みの形・一文の説明・**例を書き換えたのに撮り直していないもの**を見る。
# 指紋が見ていない範囲 (実装の変更) は合否に混ぜず要約で言う
example-shots-check:
	python3 scripts/example-shots.py

# 参照スケッチの絵。**リポジトリには置かない** — 撮った絵は Gyazo へ上げて URL で
# 参照する。同じフレーム番号を描くので、撮り直せば同じ絵になる
reference-shots: ## 参照スケッチの絵を書き出す (OUT= で置き場を指定)
	swift run reference-sketches --render "$(or $(OUT),shots)"

# ワイヤフォーマットの正典は Schemas/ の JSON Schema で、実装が従う側になる
# (ADR-0018 決定 4)。代表例をスキーマで検証し、正典と例がずれたら落とす
schemas:
	bash scripts/check-schemas.sh
