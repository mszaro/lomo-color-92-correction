#!/usr/bin/env ruby
# Side-by-side contact sheet of two renders of the same roll, matched by
# frame name, for judging one version of a correction against another.
#
#   compare_sheet.rb LEFT_DIR RIGHT_DIR OUT.jpg [LEFT_LABEL RIGHT_LABEL]

require "vips"

left, right, out, left_label, right_label = ARGV
unless left && right && out
  warn "usage: compare_sheet.rb LEFT_DIR RIGHT_DIR OUT.jpg [LEFT_LABEL RIGHT_LABEL]"
  exit 1
end
left_label ||= File.basename(left)
right_label ||= File.basename(right)

EXTS = %w[jpg jpeg tiff tif png].freeze
TILE = 300
PAIRS_ACROSS = 3

def frames(dir)
  Dir.children(dir)
     .select { |f| EXTS.include?(File.extname(f).delete(".").downcase) }
     .to_h { |f| [File.basename(f, ".*"), File.join(dir, f)] }
end

def thumb(path)
  return blank unless path

  Vips::Image.thumbnail(path, TILE, height: TILE, size: :down).then do |im|
    im = im[0..2] if im.bands > 3
    im = (im.cast(:float) / 257.0).cast(:uchar) if im.format == :ushort
    # centre on a fixed square so every pair lines up in the grid
    im.gravity(:centre, TILE, TILE, background: [24, 24, 24])
  end
end

def blank
  Vips::Image.black(TILE, TILE, bands: 3) + 60
end

l = frames(left)
r = frames(right)
names = (l.keys | r.keys).sort

pairs = names.map do |n|
  pair = thumb(l[n]).join(thumb(r[n]), :horizontal, shim: 4, background: [24, 24, 24])
  caption = Vips::Image.text(n, dpi: 90).then do |t|
    t.gravity(:centre, pair.width, 20, background: 0)
  end
  caption = (caption > 0).ifthenelse([220, 220, 220], [24, 24, 24])
  caption.join(pair, :vertical)
end

rows = pairs.each_slice(PAIRS_ACROSS).map do |row|
  row << (Vips::Image.black(row.first.width, row.first.height, bands: 3) + 24) while row.size < PAIRS_ACROSS
  row.reduce { |a, b| a.join(b, :horizontal, shim: 16, background: [24, 24, 24]) }
end

header = Vips::Image.text("left: #{left_label}      right: #{right_label}", dpi: 110)
sheet = rows.reduce { |a, b| a.join(b, :vertical, shim: 16, background: [24, 24, 24]) }
header = (header > 0).ifthenelse([240, 240, 240], [24, 24, 24])
                     .gravity(:centre, sheet.width, 40, background: [24, 24, 24])
header.join(sheet, :vertical).jpegsave(out, Q: 88)
puts "wrote #{out} (#{names.size} frames)"
