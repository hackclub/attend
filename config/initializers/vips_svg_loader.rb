# RasterizesSvgLogo converts uploaded SVG logos to PNG with libvips, which needs
# libvips' SVG loader (librsvg) available — but libvips classes every SVG loader
# as untrusted, and two things block untrusted loaders: image_processing 2.0 on
# require, and Active Storage's active_storage/vips (the CVE-2026-66066 patch,
# Rails >= 8.1.3.1). Vips.block_untrusted(true) is a one-time sweep over
# per-operation block flags, so whichever call runs last wins. Active Storage
# loads its file lazily — eager loading in production, the engine's
# after_initialize hook elsewhere — both after config/initializers, which would
# re-block anything an initializer had re-allowed.
#
# So: force that require here (it pulls in image_processing/vips and runs the
# sweep), then re-allow just the SVG loaders (vips_operation_block_set matches
# on class-name prefix, covering VipsForeignLoadSvgBuffer and
# VipsForeignLoadSvgFile). Ruby caches requires, so Active Storage's later lazy
# load is a no-op and nothing re-blocks SVG after this point. Every other
# untrusted loader stays blocked. Rasterizing user SVG to PNG is the point of
# the feature — it is what stops SVG-borne script from ever being served back —
# and RasterizesSvgLogo already turns a librsvg failure into a validation error.
require "active_storage/vips"

Vips.block("VipsForeignLoadSvg", false)
