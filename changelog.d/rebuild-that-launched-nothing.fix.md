<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

`mokume watch` が、作り直しは通ったのに走らせるものを起動できなかった回を「作り直した」として記録していたのを直した。症状は「保存した → 作り直したと出た → 絵が止まっている」で、記録のどこにも理由が出なかった。作り直しの記録 (`.mokume/build/status.json`) に `launched` が載り、起こせなかったことが窓口と `mokume doctor` から読める。
