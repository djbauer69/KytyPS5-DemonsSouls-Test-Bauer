# KytyPS5 Demon’s Souls Test Build

Temporary Linux x86_64 build harness for testing Demon’s Souls with a hybrid KytyPS5 source tree.

The intended combination is:

- **Base renderer/runtime:** official KytyPS5 `f100f78`
- **Shader/resource work:** current PR #500 head `629600b`
- **Demon’s Souls-specific compatibility commits from PR #599:** `b2c60bd` and `fbcc0c6`

This repository is only a build/test harness. The KytyPS5 source is cloned during GitHub Actions and is not vendored here.
