require "vips"

require_relative "lomo92/version"
require_relative "lomo92/colour"
require_relative "lomo92/measurements"
require_relative "lomo92/roll_profile"
require_relative "lomo92/pipeline"

# Re-balance lab scans of Lomography LomoChrome Color '92.
#
# The scans come back flat and bleached: black point around 64 of 255, white
# point around 220, using 61% of the available range, with saturation near 0.26
# where a normal colour scan runs 0.35 to 0.50. Nothing is black, nothing is
# white, and the colour has collapsed toward grey.
#
# The thing that is NOT wrong is the white balance. Sampling white walls gives
# R/G 1.008 and B/G 1.031, so the highlights are already neutral. That matters,
# because a grey-world estimator reads the collapsed colour as red deficiency and
# adds red, pushing the frame deeper into the cast people are complaining about.
# Restoring chroma fixes the apparent cast; correcting white balance worsens it.
module Lomo92
  DEFAULTS = {
    black: 0.4,
    white: 99.7,
    neutral: 0.0,
    roll_profile: 0.85,
    wb: 1.0,
    wb_clamp: 1.55,
    shadow_wb: 0.8,
    saturation: nil,
    target_saturation: 0.42,
    max_vibrance: 3.0,
    knee: 0.22,
    max_stretch: 3.2,
    contrast: 0.15,
    chroma: 0.9,
    chroma_radius: nil
  }.freeze
end
