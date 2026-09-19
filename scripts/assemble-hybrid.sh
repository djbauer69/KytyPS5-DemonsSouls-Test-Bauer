#!/usr/bin/env bash
set -euo pipefail

BASE_SHA="f100f785dafa108bbf5b40ea8e425e08236f981a"
PR500_SHA="629600b220969380748d6d3c07f326e8abbd74be"
PR599_DS_1="b2c60bdc0ce54d2edb4a97af11b0264b3015fec0"
PR599_DS_2="fbcc0c6914a9e76ae5dc52358b935657dcfcb7d7"

rm -rf kyty
git clone https://github.com/KytyPS5/KytyPS5.git kyty
cd kyty

git checkout "$BASE_SHA"
git submodule update --init --recursive
git config user.name "Kyty Hybrid Builder"
git config user.email "actions@users.noreply.github.com"

git remote add pr500 https://github.com/TarkusR/KytyPS5.git
git fetch pr500 demons-souls-shaders

set +e
git merge --no-ff --no-edit "$PR500_SHA"
merge_status=$?
set -e

if [[ "$merge_status" -ne 0 ]]; then
  echo "Resolving known PR500 conflicts for the requested hybrid."

  # Preserve the official f100f78 renderer/runtime side where it conflicts.
  git checkout --ours     src/graphics/host_gpu/renderer/pipeline/descriptors.cpp     src/graphics/host_gpu/renderer/renderCompute.cpp     src/loader/redZonePatcher.cpp

  # Preserve current PR500 shader/resource tracking where it conflicts.
  git checkout --theirs     src/graphics/shader/recompiler/backend/spirv/spirvEmitterMemory.cpp     src/graphics/shader/recompiler/ir/passes/ResourceTracking.cpp     tests/ResourceTrackingTests.cpp

  git add     src/graphics/host_gpu/renderer/pipeline/descriptors.cpp     src/graphics/host_gpu/renderer/renderCompute.cpp     src/loader/redZonePatcher.cpp     src/graphics/shader/recompiler/backend/spirv/spirvEmitterMemory.cpp     src/graphics/shader/recompiler/ir/passes/ResourceTracking.cpp     tests/ResourceTrackingTests.cpp

  unresolved="$(git diff --name-only --diff-filter=U)"
  if [[ -n "$unresolved" ]]; then
    echo "Unresolved PR500 conflicts remain:"
    echo "$unresolved"
    exit 20
  fi

  git commit -m "hybrid: merge PR500 shader/resource work onto f100f78"
fi

git remote add pr599 https://github.com/chenxiao07/KytyPS5.git
git fetch pr599 submission/reference-demons-souls-20260913

echo "Applying PR599 Demon’s Souls-specific adapters."
git cherry-pick -X theirs "$PR599_DS_1"
git cherry-pick -X theirs "$PR599_DS_2"

echo
echo "Hybrid source assembled at:"
git rev-parse HEAD
echo
git log --oneline --decorate -20
