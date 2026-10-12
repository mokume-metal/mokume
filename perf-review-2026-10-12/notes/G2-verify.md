# G2 再検証の要点 (58eea05c)。下書き: scratchpad/PerfDrafts-G2Frame.swift (@Test 17本)
## #2365
- 確認: ShaderLibraries 145-155 (:150、options nil)。ShapePipeline 198-268、Kinds165+Common881+Shapes1558=2604行、3×3+影2+form5×3=26本
- 本文より広い: ShapePipeline は Canvas.swift:2018 で Canvas ごと → createGraphics の層1枚ごとにも Shapes の組み立てと26本。#728 射程Aは Canvas ごとの回数に未着手
- Shader.reload 149-167 (Canvas:2795 と main を譲った Task)。EffectShader.reload (:74)、Computation.reload (:102) も同形 (本文未記載)
- EffectPipeline (Canvas+Effects:91)、ImageInputPass (Canvas+Uploads:68)。Builtin の組み立てとパイプライン1本 (EffectPipeline 156-161) は encodeEffects がコマンドを開いた中 (:146)。効果の pipeline も Canvas ごと → 層ごとに Builtin。loadEffect を setup で呼べば setup に移る
- binary archive なし、pipeline 作成箇所7つ
- 原因: #1432 は 10-04 not planned、#1601 の温まった実測 (0.54ms) が根拠、「冷えた最初の起動は誰も測っていない」と明記 → 冷えた実測が無いまま取った代償
- 影響: 起動=全経路。層: EffectsAndCustom, ColorAndScale, SurfacesAndBlend。断片の保存: loadShader/makeShader 作例7本、loadEffect1本、loadComputation1本 (FieldAndFlow)
- 冷えの作り方: ~/…/com.apple.metal/ (libraries.data=原文→中間表現、functions.data=中間→機械、推測)。(a) 原文に注釈1行で前段だけ外す (b) Values に欄を足して後段も外す。同じ種で2度目に温まった値に戻ることで確かめる
## #2367
- 確認: SketchApplication 879-891/899-933、FramePresenter 68-94、SharedFrameSurface 442-452/461-475
- 受け手の間引き SharedFrameStage 315-325 は作る側が毎回繰り上げるので効かない。新しい枚ごとに readNumbers が Lookup2回+CopyValue数回 (342-347)
- 原因: 窓側は #223「出すほうだけ止める」の延長。共有面は #748 で1枚遅れて名乗る設計で「止めている間も毎リフレッシュここを通るので控えが出ないまま残ることはない」(SharedFrameSurface 432-434、SketchApplication 903-906) に頼る → 印で飛ばすなら最後の変化の後にもう1回 publish が要件
- ランタイム側は既に「変えていないリフレッシュは投入しない」を検査 (StoppedUpscaleOutletsTests.theRuntimePaysOnlyForAChange) → 印の材料はある
- 影響: noLoop 作例 PointerAndKeys、外からの pause、watch で止めている間
## #2368
- 確認: ScreenDisplayLink 199-213 tolerance なし、間隔 1/frameRate・閾値 4/frameRate (FrameDriver 49-63)
- 本文より多い: newest (SharedFrameSurface 555-578) に加え新しい枚ごとに Lookup2+CopyValue約5。止めている間は #2367 で毎回
- 訂正: 道具の link が速さを据えないのは意図した代償 (ScreenDisplayLink 79-81「画面の速さに任せるほうが遅れが最小」)
- 作る側 SetValue/Remove 約6回 (466-495)
- 原因: 予備タイマーは #874/#896。Lookup は #709/#722 の形のまま
## #2387
- 確認: RenderDevice:224、884-912/1000-1010、orderAfter 1205-1208 を commit が毎回 (:1269)。置いた層の書き換えの写し (Canvas 3391-3404)、上限4 (:1172) で本体の描き切りが増える
- 原因: 3本は #222、orderAfter は #727/#1063。encodeCarryRestore の注釈 (Canvas+Effects 224-226)「orderAfter で直列なので頭に待つ仕掛けは要らない」→ 案 D はこの種の依存を encoder ごとに洗い出す必要
- 実例: Sketches/EffectsAndCustom.swift (同じ描き場所を1フレームに6回描き直して置く → 3本を大きく超える)、GlowAndDetail も
## #2388
- 確認: Canvas+Effects 152-153/201-219、233-251、条件 Canvas:3616 (pendingBackground == nil)、4K 66MB 読み書き
- 訂正: 2回は塗らないスケッチだけ。毎フレーム background なら1回
- 原因: #1469 案A の意図した代償。1段の並びとにじみ単独はもともと写し戻しをしていたので正味0 と見積もられた。案B は「触る範囲が広い」で退けた。#767 の測りでは 1080p の写しは測れない大きさ
- 影響: GlowAndDetail、EffectsAndCustom
## #2371
- 行訂正: Builtin.metal 203-319、EffectPipeline 156-161。拡大 (細かさ<1) も同じ pipeline → upscale の段にも効く
- Effect.swift 114-125、Canvas+Effects 170-188 確認
- 重みは半径に依らないことを式で確認 (σ=r/2, offset=i·r/8, w=exp(−i²/32))。例外 0<r<1e-4 は全タップ同じ画素で絵は変わらない。全解像度の r≤8 で17回読む (Builtin 24-37)
- レジスタの割り当ては未確認 (推測)
- 原因: 冒頭注釈どおり利用者の効果と同じ規約を1本で示す設計。#771/#1778 は形の側だけ
## #2390
- 確認: ScreenDisplayLink 183-185/216-220
- 訂正: now() を読むのは FrameTiming.advance() で drawSketchFrame の頭、pollStopSignal・updatePresence・観測の後 → 揺れはコールバック時点より大きいか等しい
- 7c7b21ea は非有限の jumpTime を断ることと観測の枚でも previous を進めることで、時刻の取り方は不変
- 原因: #187 (28de42a9) から now()。公開の説明は「いまのフレームの時刻」でどちらとも矛盾しない
- 影響: 時刻を読む作例22本、deltaTime は PointerAndKeys。ADR-0025 決定6 の上限 (10枚) が絡む
## #2374
- 確認: RenderTarget:216、Canvas+Graphics 20-23、RenderTarget 495-517 commitAndWait = commit + settle
- 原因 = 見落とし: 塗りは 6ece7d3f (08-29)、makeClearedTexture は #766 (e230bce1, 09-03) で後から。塗りの注釈「確保したままの中身は決まっていないので1度塗るしかない」が古い
- 本文の見落とし: 作る費用の大半は Canvas(target:gpu:) の ShapePipeline (26本) と GlyphAtlas と予想。塗りの待ちは GPU が走っている最中に作るとき効く
- 影響: ColorAndScale, EffectsAndCustom (setup)、SurfacesAndBlend (256²)
## #2373
- 確認+補足: Canvas+Compute 283-292/305-325、Numbers:311。末尾に3回目の settleQuietly (settleCalls +3)。計算が溜まっていなければ待つのは1回
- 一部反証: orderAfter (#2387) で GPU は全投入を直列実行 → 計算の投入番号だけ待っても前のフレームが終わるまで返らない。得られるのは往復 (数十〜数百µs) と settle の回数だけ。毎フレーム読むと CPU と GPU が交互になる構造は #2387 案D 無しでは消えない
- 原因: #727 で読む口に待ち、#932/#934 で書く前の待ちを引き取った
- 影響: FieldAndFlow は 30 フレームに1度だけ読むと説明に書いて回避
## #1791
- コード不変 GrowableBuffer 124-139、:135 releaseResidency → settle
