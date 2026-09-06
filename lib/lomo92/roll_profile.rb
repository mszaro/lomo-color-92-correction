module Lomo92
  # What this roll's scan got wrong, measured across every frame in it.
  #
  # The reasoning: the lab inverted the negative with a profile built for another
  # emulsion, so each channel came back through the wrong transfer curve. That is
  # a property of the ROLL, not of any one picture. Individual frames cannot tell
  # you what it is, because a frame's statistics are dominated by its subject -
  # which is why every per-frame estimate tried here got dragged around by a
  # brown treeline or a blue sky.
  #
  # Across a whole roll the subjects vary and the scan error does not, so
  # aggregating lets the scenes cancel and leaves the error behind.
  #
  # Measured on three rolls, the signature is consistent in shape: shadows come
  # back red-shifted and badly blue-starved, converging to neutral by the
  # highlights. In log ratios against green, at luma 0.17:
  #
  #   roll 58922   R/G +0.374   B/G -1.094
  #   roll 59085   R/G +0.234   B/G -1.081
  #   roll 47791   R/G -0.105   B/G -0.401
  #
  # The shape repeats across two labs on two continents; only the magnitude
  # differs, which is why this is measured per roll rather than baked in.
  #
  # The blue collapse is the big one. B/G at a third of neutral in the shadows is
  # why dark foliage renders brown: it loses blue and green while red survives.
  class RollProfile
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    INSET = 0.05
    BINS = 256
    SAMPLES_PER_FRAME = 120_000

    attr_reader :luts, :frames, :signature

    def initialize(paths, strength: 0.85, verbose: true)
      @strength = strength
      @frames = paths.size
      hist = Array.new(3) { Array.new(BINS, 0.0) }

      paths.each_with_index do |path, i|
        accumulate(hist, path)
        print "\r  profiling #{i + 1}/#{paths.size}" if verbose
      end
      puts if verbose

      @signature = describe(hist)
      @divergence = divergence_of(hist)
      @applied = strength * damage_weight(@divergence)
      @luts = build_luts(hist)
    end

    attr_reader :divergence, :applied

    # How far apart the three channels sit, as a fraction of full scale.
    #
    # This decides how much correction a roll actually gets, because matching
    # distributions is the right tool for a broken scan and the wrong one for a
    # healthy scan. On a roll whose channels already agree, the only thing left
    # to match is the roll's own subject matter, and forcing that gave a warm
    # cast to white buildings on a roll full of sky and sea.
    #
    # The evidence is stark between rolls. Channel black points came back
    # 51/36/0 on one Portland roll, a spread of 51 levels, against 27/34/20 on
    # the Algarve roll, a spread of 14. The first is a scan inverted through the
    # wrong profile; the second is broadly fine and wants leaving alone.
    def divergence_of(hist)
      cdfs = hist.map { |h| to_cdf(h) }
      marks = [0.02, 0.1, 0.25, 0.5, 0.75]
      spreads = marks.map do |q|
        vals = cdfs.map { |cdf| invert(cdf, q) }
        (vals.max - vals.min) / (BINS - 1).to_f
      end
      spreads.sum / spreads.size
    end

    # Below CLEAN the channels agree well enough to leave alone; above BROKEN the
    # scan is clearly inverted wrong and gets the full correction.
    CLEAN = 0.045
    BROKEN = 0.115

    def damage_weight(d)
      return 0.0 if d <= CLEAN
      return 1.0 if d >= BROKEN

      t = (d - CLEAN) / (BROKEN - CLEAN)
      t * t * (3 - 2 * t)
    end

    private

    def accumulate(hist, path)
      image = Colour.load(path)
      w = image.width
      h = image.height
      dx = (w * INSET).to_i
      dy = (h * INSET).to_i
      inner = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)

      factor = Math.sqrt(inner.width * inner.height / SAMPLES_PER_FRAME.to_f).floor
      inner = inner.subsample(factor, factor) if factor > 1

      raw = (inner * (BINS - 1)).cast(:uchar).write_to_memory.unpack("C*")
      bands = inner.bands
      raw.each_slice(bands) do |px|
        hist[0][px[0]] += 1
        hist[1][px[1]] += 1
        hist[2][px[2]] += 1
      end
    end

    # Where each channel sits, so the profile can be reported rather than
    # applied blind.
    def describe(hist)
      (0..2).map do |c|
        total = hist[c].sum
        cum = 0.0
        marks = {}
        hist[c].each_with_index do |n, v|
          cum += n
          [1, 50, 99].each { |p| marks[p] ||= v if cum / total >= p / 100.0 }
        end
        { p1: marks[1], p50: marks[50], p99: marks[99] }
      end
    end

    # Per-channel curves that bring the three channels' roll-wide distributions
    # into agreement.
    #
    # Across a whole roll of daylight photographs the three channels should span
    # broadly the same range: the average of many varied scenes is not strongly
    # coloured, even though any single scene may be. Where they disagree it is
    # the scan, not the world. So each channel is mapped onto the average of the
    # three by matching quantiles.
    #
    # This is deliberately not the same as grey-world. Grey-world forces the MEAN
    # of one frame to neutral and so is captured by whatever dominates that
    # frame. This matches whole DISTRIBUTIONS across the whole roll, which fixes
    # the black point, the crushed blue and the tone-dependent cast together,
    # because it corrects the shape of each channel's transfer rather than
    # sliding it.
    def build_luts(hist)
      cdfs = hist.map { |h| to_cdf(h) }
      target = Array.new(BINS) { |v| (cdfs[0][v] + cdfs[1][v] + cdfs[2][v]) / 3.0 }

      (0..2).map do |c|
        raw = Array.new(BINS) { |v| invert(target, cdfs[c][v]) }
        blended = raw.each_with_index.map do |mapped, v|
          v + (mapped - v) * @applied * highlight_taper(v)
        end
        monotonic(smooth(blended))
      end
    end

    # Leave the highlights alone.
    #
    # Highlight neutrality measures 0.98 to 1.03 in R/G on all three rolls, from
    # two different labs, so the bright end of these scans is already right and
    # only the shadows and midtones are wrong. Matching whole distributions would
    # still shuffle the highlights, and on a roll that leans blue overall (a lot
    # of sky and sea) that came back as a warm cast on white walls.
    #
    # So the correction fades out toward white, which puts it where the error
    # actually is and protects what was never broken.
    TAPER_START = 200
    TAPER_END = 250

    def highlight_taper(value)
      return 1.0 if value <= TAPER_START
      return 0.0 if value >= TAPER_END

      t = (value - TAPER_START).to_f / (TAPER_END - TAPER_START)
      0.5 * (1 + Math.cos(Math::PI * t))
    end

    def to_cdf(h)
      total = h.sum
      return Array.new(BINS) { |v| v.to_f / (BINS - 1) } if total <= 0
      cum = 0.0
      h.map { |n| cum += n; cum / total }
    end

    # Where does this cumulative probability sit in the target distribution?
    def invert(target, q)
      lo = 0
      hi = BINS - 1
      while lo < hi
        mid = (lo + hi) / 2
        target[mid] < q ? lo = mid + 1 : hi = mid
      end
      return lo.to_f if lo.zero?

      prev = target[lo - 1]
      span = target[lo] - prev
      span <= 1e-12 ? lo.to_f : (lo - 1) + (q - prev) / span
    end

    # Quantile matching on a noisy histogram is jagged, and a jagged curve shows
    # as banding in flat areas like sky.
    def smooth(curve, passes: 3, radius: 4)
      out = curve.dup
      passes.times do
        prev = out.dup
        out = out.each_index.map do |i|
          lo = [i - radius, 0].max
          hi = [i + radius, BINS - 1].min
          prev[lo..hi].sum / (hi - lo + 1).to_f
        end
      end
      out
    end

    # A transfer curve that doubled back would invert tones locally.
    def monotonic(curve)
      running = -Float::INFINITY
      curve.map do |v|
        running = v > running ? v : running
        running.clamp(0.0, BINS - 1)
      end
    end

    public

    def report
      names = %w[R G B]
      lines = [format("roll profile from %d frames: channel divergence %.3f -> applying %.0f%%",
                      frames, divergence, applied * 100)]
      (0..2).each do |c|
        s = signature[c]
        shift = [1, 128, 250].map { |v| (luts[c][v] - v).round }
        lines << format("  %s  black %3d  mid %3d  white %3d   shift at black/mid/white: %+d %+d %+d",
                        names[c], s[:p1], s[:p50], s[:p99], *shift)
      end
      lines.join("\n")
    end

    # As a vips lookup, ready to apply to a frame.
    def vips_luts
      luts.map { |c| Vips::Image.new_from_array([c.map { |v| v / (BINS - 1).to_f }]) }
    end
  end
end
