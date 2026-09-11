#!/usr/bin/env ruby
# How wide a spread of colours does a roll actually contain?
#
# A correctly rendered roll of daylight photographs covers a lot of colour space:
# foliage and sky and skin and brick and stone all sit in different directions.
# A cast does not merely slide that distribution, it squashes it - a channel that
# has been clipped loses its whole lobe, so the colours that depended on it stop
# appearing at all.
#
# That gives a test that never asks which pixels are neutral, which is the
# question that turned out to be circular: a probe that picks low-chroma pixels
# out of an image whose colour is in doubt will, on a yellow-cast frame, select
# the genuinely blue objects and call them grey.
#
# Instead this asks whether the spread of colours is plausible. One frame may
# honestly be narrow, a foggy seascape or a close-up of a red door. A whole roll
# of varied scenes should not be.
#
# Prints the share of chroma falling in each hue sector, per roll.

require "vips"

SECTORS = 12
LUMA = [0.2126, 0.7152, 0.0722].freeze

def histogram(path)
  im = Vips::Image.new_from_file(path, access: :random)
  im = im[0..2] if im.bands > 3
  im = im.cast(:float)
  im /= 257.0 if im.max > 256

  y = (im * LUMA).bandmean * 3.0
  ry = im[0] - im[1]
  by = im[2] - (im[0] + im[1]) / 2.0
  chroma = ((ry * ry) + (by * by))**0.5

  # Only pixels with real colour, and not the near-black or near-clipped ends
  # where everything crowds together regardless.
  usable = (y > 25) & (y < 235) & (chroma > 6)

  counts = Array.new(SECTORS, 0.0)
  SECTORS.times do |s|
    lo = (s * 360.0 / SECTORS) - 180
    hi = ((s + 1) * 360.0 / SECTORS) - 180
    # atan2 as a comparison on the two opponent axes, sector by sector.
    angle = angle_mask(ry, by, lo, hi)
    counts[s] = (usable & angle).ifthenelse(1, 0).avg
  end
  total = counts.sum
  total <= 0 ? counts : counts.map { |c| c / total }
end

# Whether each pixel's hue angle falls inside one sector, without atan2.
def angle_mask(ry, by, lo_deg, hi_deg)
  lo = lo_deg * Math::PI / 180
  hi = hi_deg * Math::PI / 180
  # Rotate so the sector starts at zero, then test the half planes.
  above = (by * Math.cos(lo) - ry * Math.sin(lo)) >= 0
  below = (by * Math.cos(hi) - ry * Math.sin(hi)) < 0
  above & below
end

NAMES = %w[cyan cyan+ blue- blue blue+ mag- mag mag+ red red+ yel- yel].freeze

def survey(dir, pattern, label, limit)
  files = Dir.glob(File.join(File.expand_path(dir), pattern)).sort.first(limit)
  totals = Array.new(SECTORS, 0.0)
  if files.empty?
    puts "\n#{label}: no frames found"
    return nil
  end
  files.each { |f| histogram(f).each_with_index { |v, i| totals[i] += v } }
  totals.map! { |t| t / files.size }

  puts "\n#{label} (#{files.size} frames)"
  bar = totals.map { |t| "#" * (t * 120).round }
  SECTORS.times do |s|
    puts format("  %-6s %5.1f%%  %s", NAMES[s], totals[s] * 100, bar[s])
  end
  # How evenly the colour is spread: 1.0 would be perfectly uniform.
  entropy = -totals.sum { |t| t > 0 ? t * Math.log(t) : 0 } / Math.log(SECTORS)
  puts format("  spread %.3f  (1.000 = colour in every direction, 0 = all one way)",
              entropy)
  totals
end

limit = (ENV["LIMIT"] || "10").to_i
DL = File.expand_path("~/Downloads")
survey("#{DL}/58922", "*.jpg", "58922 SOURCE", limit)
survey("#{DL}/58922 - corrected", "*.jpg", "58922 CORRECTED (shipped)", limit)
survey("#{DL}/47791 Lomography Color 92", "*.tiff", "47791 SOURCE", limit)
survey("#{DL}/47791 Lomography Color 92 - corrected", "*.tiff", "47791 CORRECTED", limit)
