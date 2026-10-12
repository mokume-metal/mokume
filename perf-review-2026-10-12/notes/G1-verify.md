# G1 再検証の要点 (58eea05c、Drawing に差分なし)
## #2364
- encodeBatches 3943-4100: 重複除去は viewport(pinnedFar) のみ。pipeline/depth 3975-4006、frontFacing/cull 4023-4024、scissor 4040、argTable 4066
- setAddress は 9〜11 回 (平面11/基本9/立体10)、setTexture 5、gpuResourceID 5。列あたり Metal 呼び出し約22。2万列で約44万+10万
- 訂正: uploadPerBatch(4312-4410) が書くのは stride 分のみ: FlatFrame112+Lighting112+Material48+Surroundings48+values16(線176) ≈336B/列(線496B)。2万列で約8MB (25.6MB は置き場の大きさ)
- 本文より広い: 基本図形の断片は FlatFrame しか読まない → 5本中4本と setAddress4回が無駄
- 走査: enumerated 7本 (4320,4367,4382,4390,4404,3966,Sweep:45) + for batch 3647,3572、影あり 4614,4722,4731,4811
- 原因: 列の番号×256B 窓の形を全 source に適用 (ADR-0021 決定2・3)。重複除去は最初から無い
- 見込み: PR #1741 線ありの球100個(200列) 0.337ms → 列1本 ≈1.7µs 上限
## #2366
- 確認: Canvas 3999-4006, ShapePipeline 58-67, 490-497。blendingState 設定は2か所のみ。mokume_fragmentDirect(Common.metal:850) は discard も深度書き込みも無し
- 反証: 粒の雲は GPU が色/α を書くので CPU で不透明判定不可 → 対象外
- 補足: cullMode(for:) (Canvas+Style 392)・placementMayShowBackFaces(448)・backFaceInstances が同種の述語を持つ。条件に thinCoverage==false
- 原因: #774 (5cd49a80) で既定の混ぜ方を固定機能へ。混ぜ方ごとに組み不透明で分けない。HSR に触れた Issue は初
- 影響: 光と影の 3D で奥→手前。参照スケッチは重なり浅い
## #2385
- 全主張確認: SolidStrokeGeometry 272-288 (277,287)、値128、Canvas 4418、Canvas+Solid 215、Canvas+Style 356,553-558
- 原因: ADR-0021 決定2 (0021:69) の意図した代償。PR #1741 の頃から描画回数200
- B だけでは列数が変わらず効果薄。B のシェーダ変更は #1796 と同じ → #1796 先行で土台
- C で絵が変わる仕組み: (1)細い線は被覆<1で順序依存 (2)別の形の塗りと線が同じ奥行きで lessEqual の勝ち負け。同じ形は線を(太さ+1)px 視点側へ寄せる(Shapes.metal 668-675)ので競らない
- 影響: 既定スタイルで立体を並べる初心者の書き方に直撃。参照スケッチは SolidsAndLight 6個・CrowdAndModel 1個
## #2386
- 確認: SolidMesh 40-47、Canvas+Solid 215-250、Canvas.swift:2488 で毎フレーム空
- 補足: SolidMesh 自体は solidMeshes(16MiB) にフレームをまたいで残る。寸法固定なら詰め直しと写しだけ
- 本文の見落とし: 線の骨 sharedGPUStrokeGeometry (SolidStrokeGeometry 235-266) は球だけ半径を鍵から外す。箱などは寸法ごとに稜線溶接と MTLBuffer 確保 → 寸法を動かす箱は毎フレーム GPU 置き場を確保・retire。費用の主役の可能性
- 訂正: 円柱・円錐は (r,h,r)、楕円体は軸ごとの拡大で表せる。比が形を変えるのはトーラスだけ (SolidMesh 220-330)
- 箱と平面は拡大でビット一致も見込める (±w/2 厳密、法線は寸法非依存 118-167)
- ADR-0023 決定5 改訂 (0023:102) が「外せる控えは外してよい」→ 箱・平面の線の骨を寸法から外すのは既存採択の範囲
## #2380
- 本文より広い: 片は点ごとに2枚 → 同じ点の形を12頂点が解く (重複11/12)。円板の片8枚の点は60頂点 (plane のみ、PR #2177)
- 確認: Shapes.metal 423-547, 335-336/362/472-478, 557, 580, 591
- 原因: PR #2168 (1369d7e5) で角の形を頂点関数が決める形に。線の GPU 時間 ×1.10〜1.37 を測り「2倍を越えない」として受け入れた意図した代償
- 影響: 既定細かさ24の球400個の線 約2.5ms (#2168, 800×800)
## #2384
- cos/sin: Shapes.metal 1078-1079。塗り+輪郭では同じ引数で2回呼ぶ(1303-1305) → 最大8回 (CSE の可能性)
- instances 読み: flat で同じ添字 → ほぼ揃って読む。flat varying 化はむしろ重くなりうる (疑わしい)
- unitsPerPixel 軽微。6頂点: Canvas 4703 / Shapes 823-910、1万個で6万頂点と小さい
- 一周の扇形は楕円経路へ (Canvas+Primitives 97-102)
- 原因: #772 (19a77335) の形のまま。参照スケッチは ShapesAndStyle 1か所
## 既存
- #1795: 粒も通る (plane(1,1) の保持形 Canvas+Particles 78-86、openRetainedSolid :269、solidStates kShapeLit=true、bakeActiveLights)。案1 の判定を「立体の塗りの列・断片なし・光も周囲も無い」にすれば粒も入るが、完了条件2の検査と台帳に粒が無い
- #1796: 変化なし、関係 PR 無し。#2385 B と同じシェーダ変更
- #939 材料2: 未計測。モデルは添字なしで 96B/頂点 (Canvas+Solid 281-297)、60万頂点で58MB
