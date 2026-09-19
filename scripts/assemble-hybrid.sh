#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

# PR599's CMake conflict context carries a generic test target from its older parent
# series, but this hybrid intentionally imports only the two Demon's Souls adapters.
# Remove that stale EXCLUDE_FROM_ALL target; it is not part of the emulator build.
sed -i '/add_executable(page_protection_table_tests/,/target_include_directories(page_protection_table_tests/d' CMakeLists.txt

# PR599's verified linear-copy shortcut depends on a generic alias-proof helper
# that is not present in the f100f78 memory model. Preserve correctness by
# declining that optimization; the original shader path remains the fallback.
python3 - <<'PY'
from pathlib import Path
p = Path("src/graphics/host_gpu/renderer/demonsSouls.cpp")
s = p.read_text()
old = """\tif (!LibKernel::Memory::IsUniqueGuestBackingRange(src, bytes) ||
\t    !LibKernel::Memory::IsUniqueGuestBackingRange(dst, bytes) ||
\t    !LibKernel::Memory::IsUniqueGuestBackingRange(parameters.Base48(), 16))
\t\treturn false;
"""
new = """\t// Hybrid base lacks PR599's generic physical-alias proof. Do not lower this
\t// shader to a host copy unless that proof is available; use the original shader.
\treturn false;
"""
if old not in s:
    raise SystemExit("expected PR599 linear-copy alias guard not found")
p.write_text(s.replace(old, new, 1))
PY

# Adapt PR599's Demon’s Souls compute-chain changes to the current PR500/f100
# DispatchDirect API. PR500 added indirect_args and expanded meta-clear inputs;
# PR599's older implementation used pre-resolved indirect_buffer/offset variables.
python3 - <<'PY'
from pathlib import Path

p = Path("src/graphics/host_gpu/renderer/renderCompute.cpp")
s = p.read_text()

import re

meta_pattern = re.compile(
    r"bool RenderExecutor::TryConsumeComputeMetaClear\(const ShaderComputeInputInfo& input,\s*"
    r"const CommandBuffer&\s+buffer\) \{"
)
s, meta_count = meta_pattern.subn(
    "bool RenderExecutor::TryConsumeComputeMetaClear(const ShaderComputeInputInfo& input,\n"
    "                                                 const CommandBuffer& buffer, uint32_t group_x,\n"
    "                                                 uint32_t group_y, uint32_t group_z,\n"
    "                                                 uint32_t mode) {",
    s,
    count=1,
)

dispatch_pattern = re.compile(
    r"void RenderExecutor::DispatchDirect\(uint64_t submit_id, CommandBuffer& buffer,\s*"
    r"uint32_t thread_group_x, uint32_t thread_group_y,\s*"
    r"uint32_t thread_group_z, uint32_t mode\) \{"
)
s, dispatch_count = dispatch_pattern.subn(
    "void RenderExecutor::DispatchDirect(uint64_t submit_id, CommandBuffer& buffer,\n"
    "                                     uint32_t thread_group_x, uint32_t thread_group_y,\n"
    "                                     uint32_t thread_group_z, uint32_t mode,\n"
    "                                     uint64_t indirect_args) {",
    s,
    count=1,
)
if dispatch_count != 1:
    raise SystemExit(f"expected one DispatchDirect signature, patched {dispatch_count}")

# Direct-only early exits must not discard an indirect dispatch whose group counts
# are supplied by the guest argument buffer.
s = s.replace(
    "if (thread_group_x == 0 || thread_group_y == 0 || thread_group_z == 0) {",
    "if (indirect_args == 0 && (thread_group_x == 0 || thread_group_y == 0 || thread_group_z == 0)) {",
    1,
)

# If the f100 meta-clear call survived the merge, update it to PR500's API.
s = s.replace(
    "if (TryConsumeComputeMetaClear(input_info, buffer)) {",
    "if (indirect_args == 0 && TryConsumeComputeMetaClear(input_info, buffer, thread_group_x,\n"
    "                                                     thread_group_y, thread_group_z, mode)) {",
    1,
)

old_indirect = """if (indirect_args != 0) {
		vk::BufferMemoryBarrier args_barrier {};
		args_barrier.sType         = vk::StructureType::eBufferMemoryBarrier;
		args_barrier.srcAccessMask = vk::AccessFlagBits::eShaderWrite |
		                             vk::AccessFlagBits::eTransferWrite |
		                             vk::AccessFlagBits::eMemoryWrite;
		args_barrier.dstAccessMask       = vk::AccessFlagBits::eIndirectCommandRead;
		args_barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		args_barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		args_barrier.buffer              = indirect_buffer;
		args_barrier.offset              = indirect_offset;
		args_barrier.size                = 3u * sizeof(uint32_t);
		if (!continues_chain) vk_buffer.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands,
		                          vk::PipelineStageFlagBits::eDrawIndirect,
		                          vk::DependencyFlags {}, 0, nullptr, 1, &args_barrier, 0, nullptr);
		vk_buffer.dispatchIndirect(indirect_buffer, indirect_offset);
	} else {
		vk_buffer.dispatch(thread_group_x, thread_group_y, thread_group_z);
	}"""
new_indirect = """if (indirect_args != 0) {
		auto [args_buffer, args_offset] = m_context.GetBufferCache().ObtainBuffer(
		    indirect_args, 3u * sizeof(uint32_t), false, false, BufferId {});
		vk::BufferMemoryBarrier args_barrier {};
		args_barrier.sType         = vk::StructureType::eBufferMemoryBarrier;
		args_barrier.srcAccessMask = vk::AccessFlagBits::eShaderWrite |
		                             vk::AccessFlagBits::eTransferWrite |
		                             vk::AccessFlagBits::eMemoryWrite;
		args_barrier.dstAccessMask       = vk::AccessFlagBits::eIndirectCommandRead;
		args_barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		args_barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		args_barrier.buffer              = args_buffer->Handle();
		args_barrier.offset              = args_offset;
		args_barrier.size                = 3u * sizeof(uint32_t);
		if (!continues_chain) {
			vk_buffer.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands,
			                          vk::PipelineStageFlagBits::eDrawIndirect,
			                          vk::DependencyFlags {}, 0, nullptr, 1, &args_barrier, 0, nullptr);
		}
		vk_buffer.dispatchIndirect(args_buffer->Handle(), args_offset);
	} else {
		vk_buffer.dispatch(thread_group_x, thread_group_y, thread_group_z);
	}"""
if old_indirect not in s:
    raise SystemExit("expected PR599 indirect-dispatch block not found")
s = s.replace(old_indirect, new_indirect, 1)

p.write_text(s)
PY

# Port PR599's sampled mip-view clamping onto the newer f100f78 descriptor
# implementation. Keep the physical allocation at MaxMip+1 and clamp ordinary
# sampled views to that allocation instead of growing the image and changing
# the PS5 tiled layout.
python3 - <<'PY'
from pathlib import Path

p = Path("src/graphics/host_gpu/renderer/pipeline/descriptors.cpp")
s = p.read_text()

old_levels = """	const auto physical_levels = multisampled ? 1u : static_cast<uint32_t>(max_mip) + 1u;
	const auto levels =
	    multisampled ? 1u : std::max(physical_levels, static_cast<uint32_t>(last_level) + 1u);
"""
new_levels = """	const auto physical_levels = multisampled ? 1u : static_cast<uint32_t>(max_mip) + 1u;
	const auto levels          = physical_levels;
	const bool dynamic_storage =
	    storage && resource.mip_mode == ShaderRecompiler::IR::ImageMipMode::DynamicStorage;
	const auto view_last_level =
	    !multisampled && !dynamic_storage ? std::min(last_level, max_mip) : last_level;
"""
if old_levels not in s:
    raise SystemExit("f100 mip-level block not found")
s = s.replace(old_levels, new_levels, 1)

old_validate = """	if ((!multisampled && base_level > last_level) ||
	    (multisampled &&
"""
new_validate = """	if ((!multisampled && (base_level > view_last_level || view_last_level >= levels)) ||
	    (multisampled &&
"""
if old_validate not in s:
    raise SystemExit("f100 mip validation block not found")
s = s.replace(old_validate, new_validate, 1)

old_view = """	const auto view_levels =
	    multisampled ? 1u : static_cast<uint32_t>(last_level - base_level) + 1u;
"""
new_view = """	const auto view_levels =
	    multisampled ? 1u : static_cast<uint32_t>(view_last_level - base_level) + 1u;
"""
if old_view not in s:
    raise SystemExit("f100 view-level block not found")
s = s.replace(old_view, new_view, 1)

start = s.find("	if (levels > physical_levels) {")
if start == -1:
    raise SystemExit("f100 physical-layout expansion guard not found")
end = s.find("	uint32_t      pitch = 0;", start)
if end == -1:
    raise SystemExit("f100 physical-layout guard end not found")
s = s[:start] + s[end:]

p.write_text(s)
PY

# Keep sampled depth/stencil tracking and Vulkan feedback state consistent across
# the retained f100 descriptors and PR500 render-target code.
git apply --check "$HARNESS_DIR/patches/depth-stencil-feedback.patch"
git apply "$HARNESS_DIR/patches/depth-stencil-feedback.patch"

# Port the two tiny generic helpers required by PR599's Demon’s Souls adapters
# onto the f100f78 interfaces, without importing PR599's broader generic series.
python3 - <<'PY'
from pathlib import Path

# 1) Coherent host-write preparation: f100f78 already exposes the renderer's
# InvalidateMemory path, so add the boolean wrapper expected by demonsSoulsCopy.
h = Path("src/kernel/memory.h")
hs = h.read_text()
decl_anchor = "void                   InvalidateMemory(uint64_t vaddr, uint64_t size);\n"
if "TryPrepareHostWrite" not in hs:
    if decl_anchor not in hs:
        raise SystemExit("memory.h insertion anchor not found")
    hs = hs.replace(
        decl_anchor,
        decl_anchor + "bool                   TryPrepareHostWrite(uint64_t vaddr, uint64_t size);\n",
        1,
    )
    h.write_text(hs)

cpp = Path("src/kernel/memory.cpp")
cs = cpp.read_text()
if "bool TryPrepareHostWrite(uint64_t vaddr, uint64_t size)" not in cs:
    impl_anchor = """void InvalidateMemory(uint64_t vaddr, uint64_t size) {
	if (size == 0) {
		return;
	}
	(void)GetGpuResources().InvalidateMemory(vaddr, size);
}
"""
    if impl_anchor not in cs:
        raise SystemExit("memory.cpp insertion anchor not found")
    helper = impl_anchor + """
bool TryPrepareHostWrite(uint64_t vaddr, uint64_t size) {
	return g_gpu_resources != nullptr && IsGpuAddressRange(vaddr, size) &&
	       g_gpu_resources->InvalidateMemory(vaddr, size);
}
"""
    cs = cs.replace(impl_anchor, helper, 1)
    cpp.write_text(cs)

# 2) PR599's idle-poll adapter specifically asks for a non-spinning short sleep.
# Keep f100f78's existing high-resolution SleepMicro unchanged and add a separate
# yielding path for this compatibility adapter.
th = Path("src/common/threads.h")
ths = th.read_text()
if "SleepMicroWithoutSpinning" not in ths:
    anchor = "\tstatic void SleepMicro(uint32_t micros);\n"
    if anchor not in ths:
        raise SystemExit("threads.h insertion anchor not found")
    ths = ths.replace(
        anchor,
        anchor + "\tstatic void SleepMicroWithoutSpinning(uint32_t micros);\n",
        1,
    )
    th.write_text(ths)

tc = Path("src/common/threads.cpp")
tcs = tc.read_text()
if "void Thread::SleepMicroWithoutSpinning" not in tcs:
    anchor = """void Thread::SleepNano(uint64_t nanos) {
"""
    if anchor not in tcs:
        raise SystemExit("threads.cpp insertion anchor not found")
    helper = """void Thread::SleepMicroWithoutSpinning(uint32_t micros) {
	std::this_thread::sleep_for(std::chrono::microseconds(micros));
}

"""
    tcs = tcs.replace(anchor, helper + anchor, 1)
    tc.write_text(tcs)
PY

echo
echo "Hybrid source assembled at:"
git rev-parse HEAD
echo
git log --oneline --decorate -20
