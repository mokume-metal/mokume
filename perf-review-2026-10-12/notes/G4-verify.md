# G4 再検証の要点 (58eea05c)。下書き: scratchpad/drafts-G4/G4Media.swift (787行), G4Audio.swift (136行)
## #2372
- 確認: .utility MovieWriter:111, FrameWriter:239 (WriteLanes.enqueue)。Backpressure:54 上限4, 125-134 take() の slots.wait() (:127)。呼ぶのは MovieWriter.write(:154)/FrameWriter.write(:101)、FrameRecorder.receive(:437) から main
- 寄付されない: 仕組みとして確認。E コアへ回るかは推測 — 本当に重いのは ProRes 4444 ソフト符号化器 (MovieFile:186、#1813) の内部スレッドで、その QoS が utility を継ぐかは不明
- 0 埋め EncodedImage:107 (105-119)。行ごと memcpy は 4K でも 2160 回 → 主因は 0 埋めとページフォルトと推測
- PNGFile:47 の写しは PNG 符号化より桁違いに小さい見込み
- 見落とし: 連番 PNG は WriteLanes が最大4本並列、直列は動画だけ。MovieFile.append は isReadyForMoreMediaData を Task.sleep(1ms) で待つ (:296)。兄弟: FrameConverter.picture (:157)・縮める道 (:86) も 0 埋め→上書き
- 原因: .utility は #470 (48a7b026)・#488 (ee8a550c) から、理由の記述なし。semaphore は ADR-0010 決定4 の帰結 (main は同期の draw 内で await できない)。組み合わせを意図した跡なし = 見落とし。0 埋めは f2f0ff0e (#453) から不変
- 影響: beginRecord (.mov/連番)、save()、mokume render、OutputFrame.bytes()。beginRecord を使う Sketch 0 本、Docs 1件
- 見込み: 4K ではソフト ProRes が 60fps に届かず毎フレーム背圧 → 主因は #1813 (範囲外) で優先度ではない可能性
## #2375
- 確認: Particles.metal 145-162 (1M で初段 3907 スレッド)、flag 126-135、update 168-300、SolidInstance 71-77/288-299 (normal0-2 は視点の枠)、Canvas+Compute 264-271 (threadExecutionWidth、利用者の compute 全部に効く)、Canvas+Particles 214-232
- 原因 (意図した代償): PR #769 (ac87bc48) が案1 (simd_prefix_exclusive_sum: threadgroup の組み方に依存し段が変わった日に黙って壊れる、Particles.metal:139-141) と案3 (32B インスタンス: 実害が出てから) を明示的に退けた。同 PR の Metal System Trace で 1M 容量・生存1割の計算全体 0.44 ms、生存ほぼ全部でもフレーム時間不変 (7.1–8.7 ms)
- 評価: scan 直列は数十 µs 級で主費用でない。全部生きているときの update 書き込み (1M で 128MB/フレーム) と flag の全状態読み 56MB が支配的と推測
- 影響: 作例 SparksInSpace (16k+2.4k)、SparksAndForces (24k)。10万に届かない
## #2379
- 訂正 (本文より広い): 条件は isActive で stop() (:195) は戻さない、エフェクトも connect で true (SoundEffect:82) → 一度でも鳴らした音・繋いだエフェクトは止めた後も毎フレーム解析。上限 SynthRack.capacity=64
- 確認: SynthStage 159-160 → SynthSound 101-107、AudioAnalysis:69 setup 毎回、:70 複素DFT、:76-81 スカラー、:85 512回 log10、SampleRing 60-66 の map 含め確保 7-8 個
- 原因 (前提崩れ): コメント :68「フレームに1度で数十µs」はマイク1本時代 (#2160 0760addc) の前提。合成音 (#2221 5bd4291d) で崩れた。SoundFile も同じ道
- 影響: 作例 SynthAndFilter 1本 (12個解析、読むのは8個)
## #2381
- 確認: SketchRuntime 1417-1475 continueCapture (読み戻し :1443、writeFrame :1444、統計 :1450)
- 追加: encodeToImageAndRead が gpu.waitForSubmission (RenderTarget+Output:60) → 撮る枚ごとに CPU と GPU の重なりが切れる
- 訂正: FrameStats.summarize は 64×64 だけ → 数十µs 級で小さい
- FrameObserver 99-119。frameRate/frameTimeMs に混ざるのは確認 (RuntimeLoad.sample(tempo:)、window 60)
- 既定 scale 1 (原寸)、MCP も省略時原寸・最大120枚
- 原因: #212 (cafd98ce) から同期。#1745/#1752 は中間配列と変換を省いたが同期は残した。ADR-0018 に同期を選んだ理由なし
## #1792
- 焼き場 rgba16Float (GlyphAtlas:78) 8B/px、4096² 頁で 128MiB。1字ごとに 16bit float 拡張線形 P3 の CGContext (498-529)、0埋め配列、全画素色判定
- Key.size は丸めない textSize (Canvas+Glyph 68-70) → 大きさを連続で変えると全字が新しい鍵、焼くたびに settleBeforeWriting (:418)、頁が埋まると grow/rebake
- 決定 (待ちを外す) は形式と鍵の費用を扱っていない
## ADR-0042 決定5
- 当時 (#487・PR #604、1080p 最速) write() 1.74 ms、GPU へ送るまで 2.20 ms。当時は FrameConverter (vImage 色変換・0埋め・α上書き) が無かった
- いまの Image.write は 1M 画素以上なら参照を置くだけ (#1771 74f3a8b4)、描き切りで 8bit を足場へ memcpy し GPU 復号。カメラは受け取りの待ち行列で変換、動画は main (MovieReader:156)
## #1960
- 読み直し: ループ継ぎ目・jump で後ろ・1秒より先 (MovieReader 128-160, 173-192)。1秒以内は間のコマを全部 main で復号 (30fps で最大30コマ)。PR #2202 は「4K HEVC で予算に収まるかは測っていない」と明記
- テストで動画を作れる (Tests/MokumeCameraTests/TestMovie.swift)
