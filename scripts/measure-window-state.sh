#!/bin/bash
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
#
# 名前で選んだ窓の状態を 1 行で出す (#704)。
#
# ## なぜ要るか
#
# 見張り (`mokume watch`) は保存のたびに子を入れ替える。窓を**子が**持っていると、
# そのたびに窓が死に、全画面とどの画面に置いたかが失われる — 位置を覚えて開き直しても
# 戻らない (ADR-0032 決定 1)。直ったことは目では言えないので、窓の属性を読む。
#
# ## 名前で選ぶ
#
# **`window 1` を掴んではいけない。** 全画面の遷移中は無名の窓が増え (実測では
# 1800x39 のもの)、`window 1` はそちらを掴んで `fullscreen=false` という嘘を返す。
#
# ## どのプロセスが持っていてもよい
#
# 窓の持ち主は起こし方で変わる (スケッチ自身 / 見張り)。**持ち主を決め打ちにしない** —
# 決め打ちにすると、持ち主が移った瞬間に「窓が無い」としか読めなくなる。
#
# ## 見つからなければ、候補を前へ出してから測り直す
#
# **全画面の窓は自分の Space に居り、その Space が前に出ていないと補助機能から見えない。**
# 見えないだけなのに「窓が無い」と返るので、全画面にした窓を数十秒後に測ると、消えたと
# しか読めない — 実際にそう読み違え、直っているものを壊れていると報告しかけた (#704)。
#
# だから 1 度目で見つからなければ、**候補のプロセスを前へ出してから測り直す**。候補は
# 名前に mokume を含むものと、窓の名前と同じ名前のもの (スケッチの実行ファイル名は窓の
# 名前と同じ) に絞る — 総当たりで前へ出すと、測るために画面を掻き回すことになる。
#
# 存在するかどうかだけなら CoreGraphics の窓一覧が Space をまたいで見えるが、**全画面か
# どうかは補助機能にしか無い**ので、こちらを通す。
#
# 使い方:
#   measure-window-state.sh <窓の名前>
#
# 出力例:
#   owner=mokume-cli pid=1234 pos=0,39 size=1800x1130 fullscreen=true
set -euo pipefail

TITLE="${1:?窓の名前が必要}"

osascript <<OSA
on describe(p, w)
  tell application "System Events"
    set pos to position of w
    set sz to size of w
    try
      set fs to value of attribute "AXFullScreen" of w
    on error
      set fs to "読めず"
    end try
    return "owner=" & (name of p) & " pid=" & (unix id of p) & ¬
      " pos=" & (item 1 of pos) & "," & (item 2 of pos) & ¬
      " size=" & (item 1 of sz) & "x" & (item 2 of sz) & ¬
      " fullscreen=" & (fs as text)
  end tell
end describe

tell application "System Events"
  set candidates to (every process whose background only is false)
  repeat with p in candidates
    set ws to (every window of p whose name is "$TITLE")
    if ws is not {} then return my describe(p, item 1 of ws)
  end repeat

  -- 見つからない。全画面の窓が背面の Space に居るのかもしれないので、候補を前へ出す
  repeat with p in candidates
    set n to name of p
    if n contains "mokume" or n is "$TITLE" then
      set frontmost of p to true
      delay 1
      set ws to (every window of p whose name is "$TITLE")
      if ws is not {} then return my describe(p, item 1 of ws)
    end if
  end repeat
  return "窓が無い: $TITLE"
end tell
OSA
