#!/usr/bin/env ruby
# What colour is the grain, as a distribution?
#
# The hypothesis: grain is independent randomness in three dye layers, so the
# colours of individual grain speckles should scatter with no preferred hue. If
# instead they cluster in one direction, that direction is a colour shift riding
# on the grain - and unlike a patch of sky or a grey wall, grain needs no
# identifying and is present everywhere in every frame.
#
# This is a different measurement from grain AMPLITUDE, which was tested and
# found to be pinned near 1.00 across the midtones by common-mode scan noise.
# Amplitude asks how big the grain is. This asks which way it points.
#
# Method: find pixels that are local outliers, take the direction of their
# departure from the local colour, and bin those directions by angle. A flat
# histogram means honest grain. A peak means a shift.

require "vips"

BANDS = [[10, 40], [40, 80], [80, 130], [130, 180], [180, 230]].freeze
SECTORS = 12

def analyse(path, label)
  im = Vips::Image.new_from_file(path, access: :random)
  im = im[0..2] if im.bands > 3
  im = im.cast(:float)
  im /= 257.0 if im.max > 256

  smooth = im.median(3)
  residual = im - smooth
  y = (smooth * [0.2126, 0.7152, 0.0722]).bandmean * 3.0

  # Grain direction in an opponent plane: red-vs-green against blue-vs-yellow.
  # Using the residual means the local subject colour is already subtracted, so
  # what is left is only how each speckle departs from its own surroundings.
  ry = residual[0] - residual[1]
  by = residual[2] - (residual[0] + residual[1]) / 2.0
  strength = ((ry * ry) + (by * by)) ** 0.5

  puts "\n#{label}"
  BANDS.each do |lo, hi|
    band = (y >= lo) & (y < hi)
    share = band.ifthenelse(1, 0).avg
    next if share < 0.01

    # Only speckles with a real departure; the rest is quantisation.
    cut = 1.2
    mask = (band & (strength > cut)).ifthenelse(1, 0)
    frac = mask.avg
    next if frac < 0.002

    # Mean direction. If the directions are scattered these cancel toward zero;
    # if they share a heading the mean keeps its length.
    mean_ry = (ry * mask).avg / frac
    mean_by = (by * mask).avg / frac
    mean_len = Math.sqrt(mean_ry**2 + mean_by**2)
    mean_str = (strength * mask).avg / frac

    # Concentration: how much of the typical speckle length survives averaging.
    # Near 0 means scattered and honest, near 1 means all pointing one way.
    concentration = mean_str <= 0 ? 0.0 : mean_len / mean_str
    angle = Math.atan2(mean_by, mean_ry) * 180 / Math::PI

    puts format("  tone %3d-%3d  speckles %4.1f%%  concentration %.3f  " \
                "heading %+4.0f deg  (%s)",
                lo, hi, frac * 100, concentration, angle, name_direction(angle))
  end
end

# Which way the grain leans, in plain terms.
def name_direction(angle)
  case angle
  when -180..-135 then "cyan"
  when -135..-90 then "cyan-yellow"
  when -90..-45 then "yellow"
  when -45..0 then "red-yellow"
  when 0..45 then "red"
  when 45..90 then "red-blue"
  when 90..135 then "blue"
  else "blue-cyan"
  end
end

if ARGV.empty?
  warn "usage: grain_hue.rb IMAGE [IMAGE...]"
  exit 1
end
ARGV.each { |f| analyse(f, File.basename(f)) }

puts <<~KEY

  concentration near 0  = speckles point every which way, which is real grain
  concentration high    = they share a heading, which is a shift riding on it
KEY
