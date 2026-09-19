# KytyPS5 Demon’s Souls Test Build

Temporary Linux x86_64 build harness for testing Demon’s Souls with a hybrid KytyPS5 source tree.

The intended combination is:

- **Base renderer/runtime:** official KytyPS5 `f100f78`
- **Shader/resource work:** current PR #500 head `629600b`
- **Demon’s Souls-specific compatibility commits from PR #599:** `b2c60bd` and `fbcc0c6`

This repository is only a build/test harness. The KytyPS5 source is cloned during GitHub Actions and is not vendored here.

The harness retains the sampled mip-range clamp and applies
`patches/depth-stencil-feedback.patch` to the assembled source. The latter restores
resolved sampled-aspect tracking lost when retaining the f100 descriptor code,
uses the Vulkan attachment-feedback layout for sampled writable depth/stencil
aspects across graphics stages, and enables the matching dynamic aspect mask.
Read-only layouts and unsupported-host checks remain in place.

Before building, `scripts/check-depth-feedback.py` compiles the changed policy
blocks from the assembled source with real Vulkan types and runs 47 focused
checks. These are CPU policy checks; rendering still requires a Demon’s Souls
test on the target GPU. `HYBRID-BUILD.txt` records the harness commit and workflow
run so each downloaded binary can be identified despite the generated source
tree's dirty build label.
