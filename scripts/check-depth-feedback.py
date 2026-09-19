#!/usr/bin/env python3
"""Compile the patched policy blocks with real Vulkan types and small fixtures.

This checks tracking, layout selection, descriptor validation, and dynamic state
without a GPU. It extracts the actual assembled C++ so there is no separate
implementation of the policy under test. Full rendering still needs a game run.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def between(text, start, end):
    assert text.count(start) == 1, f"Expected one source anchor: {start!r}"
    first = text.index(start)
    return text[first:text.index(end, first)]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("--compiler", default="c++")
args = parser.parse_args()
renderer = args.source / "src/graphics/host_gpu/renderer"
descriptors = (renderer / "pipeline/descriptors.cpp").read_text()
draw = (renderer / "renderDraw.cpp").read_text()
image = (renderer / "image/image.h").read_text()
tracking = between(descriptors, "\t\tif (!storage) {\n\t\t\tconst auto host_view =",
                   "\n\t}\n}\n\nvoid RenderExecutor::PrepareGraphicsBindings")
selection = between(draw, "\t\tauto writable = depth.AttachmentWriteAspects()",
                    "\n\t\t// The attachment store")
validation = between(descriptors, "\t\t\t\t\tconst bool attachment_feedback =",
                     "\n\t\t\t\t\tif ((aspect")
dynamic = between(draw, "\t\tvk_buffer.setAttachmentFeedbackLoopEnableEXT(", "\n\t}")
image_binding = between(image, "struct ImageBinding {", "\n\nclass Image final")

cpp = r'''
#include <vulkan/vulkan.hpp>
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <vector>
#define EXIT(...) throw std::runtime_error("unsupported feedback")
#define EXIT_IF(x) do { if (x) throw std::runtime_error("missing view"); } while (false)
using Aspect = vk::ImageAspectFlags;
using Bit = vk::ImageAspectFlagBits;
using Layout = vk::ImageLayout;
enum class ShaderType { Pixel, Vertex, Mesh, Hull, Local, Compute };
''' + image_binding + r'''
struct ViewInfo { Aspect aspect; };
struct CachedImageView { ViewInfo info; int view; };
struct Image { ImageBinding binding; std::vector<CachedImageView> views; };
struct Depth {
    bool depth_write_enable = false;
    Aspect writes;
    Layout baseline = Layout::eDepthStencilReadOnlyOptimal;
    struct { struct { vk::Format format; } view_info; } desc;
    Aspect AttachmentWriteAspects() const { return writes; }
};
Layout depth_attachment_layout(const Depth& depth) { return depth.baseline; }
struct Graphics { bool attachment_feedback_loop_enabled; };
struct Context { Graphics graphics; const Graphics& GetGraphics() const { return graphics; } };
namespace ImageViewOps {
Aspect DepthAspectMask(vk::Format format) {
    if (format == vk::Format::eD32Sfloat) return Bit::eDepth;
    if (format == vk::Format::eS8Uint) return Bit::eStencil;
    if (format == vk::Format::eD32SfloatS8Uint) return Bit::eDepth | Bit::eStencil;
    return {};
}
}
void Track(Image& image, ShaderType stage, int view, bool storage = false) {
    struct { ShaderType stage; } program{stage};
    struct { int image_view; } binding{view};
''' + tracking + r'''
}
Layout Select(Image& image, const Depth& depth, bool supported = true) {
    Context m_context{{supported}};
''' + selection + r'''
    return layout;
}
bool ReadAllowed(Layout layout, Aspect aspect, vk::PipelineBindPoint pipeline_bind_point) {
''' + validation + r'''
    return !((aspect & Bit::eDepth && !depth_read) ||
             (aspect & Bit::eStencil && !stencil_read));
}
Aspect DynamicMask(Layout layout, vk::Format format) {
    struct { struct { Layout image_layout; } depth_stencil_attachment; } rendering{{layout}};
    struct { Depth depth_info; } state{};
    state.depth_info.desc.view_info.format = format;
    struct Command {
        Aspect mask;
        void setAttachmentFeedbackLoopEnableEXT(Aspect value) { mask = value; }
    } vk_buffer{Bit::eDepth | Bit::eStencil};
''' + dynamic + r'''
    return vk_buffer.mask;
}
int main() {
    int checks = 0;
    auto require = [&](bool ok, const char* name) {
        ++checks;
        if (!ok) throw std::runtime_error(name);
    };
    const auto ds = Bit::eDepth | Bit::eStencil;
    const auto feedback = Layout::eAttachmentFeedbackLoopOptimalEXT;
    const auto graphics = vk::PipelineBindPoint::eGraphics;
    const auto compute = vk::PipelineBindPoint::eCompute;
    Image image{{}, {{{Bit::eDepth}, 1}, {{Bit::eStencil}, 2}}};
    Depth depth{};
    depth.depth_write_enable = true;
    depth.writes = Bit::eDepth;
    depth.baseline = Layout::eDepthAttachmentStencilReadOnlyOptimal;
    for (const auto stage : {ShaderType::Pixel, ShaderType::Vertex, ShaderType::Mesh,
                             ShaderType::Hull, ShaderType::Local}) {
        image.binding = {};
        Track(image, stage, 1);
        require(Select(image, depth) == feedback, "sampled writable depth needs feedback");
        require(ReadAllowed(Select(image, depth), Bit::eDepth, graphics),
                "selected feedback must survive descriptor commit in every graphics stage");
        require(static_cast<bool>(stage == ShaderType::Pixel
                    ? image.binding.pixel_sampled_aspects & Bit::eDepth
                    : image.binding.other_sampled_aspects & Bit::eDepth),
                "resolved aspect must be recorded in the correct stage bucket");
    }
    image.binding = {};
    Track(image, ShaderType::Vertex, 2);
    require(Select(image, depth) == depth.baseline,
            "sampling read-only stencil must preserve mixed layout while depth writes");
    depth.depth_write_enable = false;
    depth.writes = Bit::eStencil;
    depth.baseline = Layout::eDepthReadOnlyStencilAttachmentOptimal;
    require(Select(image, depth) == feedback, "writable stencil needs feedback");
    Track(image, ShaderType::Pixel, 1);
    require((image.binding.pixel_sampled_aspects | image.binding.other_sampled_aspects) == ds,
            "different stages must accumulate both host aspects");
    require(ReadAllowed(Select(image, depth), ds, graphics), "both aspects must be readable");
    bool rejected = false;
    try { (void)Select(image, depth, false); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "unsupported host must not silently fall back to GENERAL");
    image.binding = {};
    Track(image, ShaderType::Pixel, 1, true);
    require(!(image.binding.pixel_sampled_aspects | image.binding.other_sampled_aspects),
            "storage binding must not be recorded as sampled");
    require(Select(image, depth, false) == depth.baseline, "unbound attachment needs no extension");
    Track(image, ShaderType::Vertex, 1);
    depth.writes = Bit::eDepth; // A load clear, with draw depth writes still disabled.
    depth.baseline = Layout::eDepthStencilReadOnlyOptimal;
    require(Select(image, depth, false) == depth.baseline, "depth load clear is not a draw feedback write");
    for (const auto aspect : {Aspect{Bit::eDepth}, Aspect{Bit::eStencil}, ds}) {
        require(ReadAllowed(feedback, aspect, graphics), "graphics feedback accepts both aspects");
        require(!ReadAllowed(feedback, aspect, compute), "compute must not use graphics feedback");
        require(!ReadAllowed(Layout::eGeneral, aspect, graphics), "GENERAL is not feedback permission");
        require(!ReadAllowed(Layout::eDepthStencilAttachmentOptimal, aspect, graphics),
                "writable layout must remain rejected");
        require(ReadAllowed(Layout::eDepthStencilReadOnlyOptimal, aspect, graphics),
                "read-only sampling remains valid");
    }
    require(ReadAllowed(Layout::eDepthReadOnlyStencilAttachmentOptimal, Bit::eDepth, graphics),
            "mixed layout allows depth reads");
    require(!ReadAllowed(Layout::eDepthReadOnlyStencilAttachmentOptimal, Bit::eStencil, graphics),
            "mixed layout rejects stencil reads");
    require(ReadAllowed(Layout::eDepthAttachmentStencilReadOnlyOptimal, Bit::eStencil, graphics),
            "mixed layout allows stencil reads");
    require(!ReadAllowed(Layout::eDepthAttachmentStencilReadOnlyOptimal, Bit::eDepth, graphics),
            "mixed layout rejects depth reads");
    require(DynamicMask(feedback, vk::Format::eD32SfloatS8Uint) == ds, "enable both feedback aspects");
    require(DynamicMask(feedback, vk::Format::eD32Sfloat) == Bit::eDepth, "depth-only feedback mask");
    require(DynamicMask(feedback, vk::Format::eS8Uint) == Bit::eStencil, "stencil-only feedback mask");
    require(!DynamicMask(Layout::eDepthStencilReadOnlyOptimal, vk::Format::eD32SfloatS8Uint),
            "next non-feedback draw must reset the dynamic mask");
    image.binding = {};
    require(!(image.binding.pixel_sampled_aspects | image.binding.other_sampled_aspects),
            "ResetBindings must clear sampled aspects");
    std::cout << "Passed " << checks << " depth/stencil feedback policy checks\n";
}
'''

with tempfile.TemporaryDirectory(prefix="kyty-depth-feedback-") as temp:
    source = Path(temp) / "check.cpp"
    binary = Path(temp) / "check"
    source.write_text(cpp)
    subprocess.run([args.compiler, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                    "-I", str(args.source.resolve() / "3rdparty/Vulkan-Headers/include"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
