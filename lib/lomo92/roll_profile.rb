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

    attr_reader :luts, :frames, :signature

    def initialize(paths, strength: 0.85, verbose: true)
      @strength = strength
      @frames = paths.size
      hist = Array.new(3) { Array.new(BINS, 0.0) }
      @per_frame = []

      paths.each_with_index do |path, i|
        @per_frame << accumulate(hist, path)
        print "\r  profiling #{i + 1}/#{paths.size}" if verbose
      end
      puts if verbose

      @signature = describe(hist)
      @agreement = agreement_curve
      @divergence = divergence_of(hist)
      @luts = build_luts(hist)
    end

    attr_reader :divergence, :agreement

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
    # Measured at the dark end only, because that is where damage and scene
    # colour can be told apart. A wrong inversion misplaces the black point, and
    # nothing in a photograph pins the darkest few percent to one hue. Midtones
    # and highlights cannot make that distinction: a roll shot around sky, sea
    # and blue tiles genuinely carries more blue up there, and reading that as
    # damage warmed its stonework into orange.
    def divergence_of(hist)
      cdfs = hist.map { |h| to_cdf(h) }
      marks = [0.01, 0.02, 0.05]
      spreads = marks.map do |q|
        vals = cdfs.map { |cdf| invert(cdf, q) }
        (vals.max - vals.min) / (BINS - 1).to_f
      end
      spreads.sum / spreads.size
    end

    private

    # Count one frame into the running histogram.
    #
    # This deliberately avoids Colour.load. That opens for random access and
    # converts to float, which costs about 300MB on a 25 megapixel scan, and
    # profiling a whole roll of them exhausts memory. Here the file is only ever
    # read once, front to back, so sequential access lets vips stream it in
    # slices and keep almost nothing.
    #
    # hist_find does the counting in C, so no pixel data crosses into Ruby.
    def accumulate(hist, path)
      image = Vips::Image.new_from_file(path, access: :sequential)
      image = image.bandjoin([image, image]) if image.bands == 1
      image = image[0..2] if image.bands > 3

      w = image.width
      h = image.height
      dx = (w * INSET).to_i
      dy = (h * INSET).to_i
      counts = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)
                    .cast(:uchar).hist_find

      frame = Array.new(3) { Array.new(BINS, 0.0) }
      BINS.times do |v|
        px = counts.getpoint(v, 0)
        3.times do |c|
          hist[c][v] += px[c]
          frame[c][v] = px[c]
        end
      end
      frame.map { |h| to_cdf(h) }
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
          v + (mapped - v) * @strength * @agreement[v]
        end
        monotonic(smooth(blended))
      end
    end

    # How much the frames agree about the channel imbalance, level by level.
    #
    # This is what separates a scan fault from the subject, and it is the only
    # thing that reliably does. A fault is in every frame of the roll: if the
    # blue record bottoms out, it bottoms out whatever was pointed at. Scene
    # colour is not - a blue sky is in some frames and not others, so the
    # imbalance it produces swings wildly between them.
    #
    # So at each level the per-frame imbalances are collected, and the systematic
    # part is kept in proportion to how much it outweighs the scatter. Where the
    # frames agree, that is the scan and it gets corrected. Where they disagree,
    # that is the pictures and it is left alone.
    #
    # This replaces a hand-set taper. A fixed cutoff had to be tuned against one
    # roll and then mis-served the other, since a badly inverted scan stays wrong
    # well into the midtones while a healthy one is only slightly off in the
    # shadows. Measuring where the evidence is makes that adjust itself.
    PROBES = [0.01, 0.02, 0.04, 0.08, 0.15, 0.25, 0.4, 0.55, 0.7, 0.85, 0.95]

    def agreement_curve
      return Array.new(BINS, 0.0) if @per_frame.size < 4

      points = PROBES.map do |q|
        offsets = @per_frame.map do |cdfs|
          vals = cdfs.map { |cdf| invert(cdf, q) }
          centre = vals.sum / 3.0
          vals.map { |v| v - centre }          # per frame, so exposure cancels
        end

        signal = 0.0
        scatter = 0.0
        (0..2).each do |c|
          col = offsets.map { |o| o[c] }
          mu = col.sum / col.size
          var = col.sum { |v| (v - mu)**2 } / col.size
          signal += mu * mu
          scatter += var
        end
        # Shrinkage: all signal and no scatter gives 1, all scatter gives 0.
        weight = signal <= 0 ? 0.0 : signal / (signal + scatter)
        [level_at(q), weight]
      end

      interpolate(points)
    end

    # Where a quantile of the roll's tones falls on the 0-255 scale, so the
    # agreement measured in quantile space can be applied in value space.
    def level_at(q)
      green = @signature[1]
      (green[:p1] + (green[:p99] - green[:p1]) * q).clamp(0, BINS - 1)
    end

    def interpolate(points)
      pts = points.sort_by(&:first)
      Array.new(BINS) do |v|
        if v <= pts.first[0] then pts.first[1]
        elsif v >= pts.last[0] then pts.last[1]
        else
          i = pts.index { |p| p[0] >= v }
          a = pts[i - 1]
          b = pts[i]
          span = b[0] - a[0]
          t = span <= 0 ? 0.0 : (v - a[0]).to_f / span
          a[1] * (1 - t) + b[1] * t
        end
      end
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
      shadow = @agreement[(BINS * 0.15).to_i]
      mid = @agreement[(BINS * 0.5).to_i]
      lines = [format("roll profile from %d frames: frames agree %.0f%% in shadows, %.0f%% in midtones",
                      frames, shadow * 100, mid * 100)]
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
