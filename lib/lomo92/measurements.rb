module Lomo92
  # Everything the pipeline needs to know about a frame before it touches it.
  #
  # All measuring happens on a downsampled copy. Sorting 25 million floats to
  # find a black point is wasted work and the answer does not move.
  class Measurements
    LUMA = [0.2126, 0.7152, 0.0722].freeze

    # The scans include a bright scanner border. Measuring it would drag the
    # white point up, so measurements work inside a fixed inset. On this roll the
    # border reaches 2.2% of the frame at worst, which makes 5% a safe margin.
    #
    # Worth knowing for other stocks: on a black and white roll the rebate is
    # dark rather than bright, since clear base inverts to near-black. Same
    # problem, except there it drags the black point down instead.
    INSET = 0.05

    attr_reader :pixels, :lumas

    # Expects a float sRGB image in 0..1, which is what the whole pipeline uses.
    #
    # Sampling takes every Nth pixel rather than scaling the image down. Scaling
    # averages neighbours, which pulls in the tails of the histogram and would
    # report a black point higher than the frame really has. Percentiles need the
    # original distribution, just less of it.
    #
    # thumbnail_image is avoided for a second reason: it reads the sRGB tag and
    # casts to 8-bit, which rounds these 0..1 floats to 0 or 1.
    TARGET_SAMPLES = 300_000

    def initialize(image, target: TARGET_SAMPLES)
      w = image.width
      h = image.height
      dx = (w * INSET).to_i
      dy = (h * INSET).to_i
      inner = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)

      factor = Math.sqrt(inner.width * inner.height / target.to_f).floor
      factor = 1 if factor < 1
      inner = inner.subsample(factor, factor) if factor > 1

      raw = inner.cast(:float).write_to_memory.unpack("f*")
      @pixels = raw.each_slice(inner.bands).map { |px| px.first(3) }
      @lumas = @pixels.map { |px| luma(px) }
    end

    def luma(px)
      LUMA[0] * px[0] + LUMA[1] * px[1] + LUMA[2] * px[2]
    end

    def saturation(px)
      mx = px.max
      mx <= 1e-6 ? 0.0 : (mx - px.min) / mx
    end

    # Linear interpolation between neighbouring ranks, the same convention numpy
    # uses, so results line up with the Python original this was ported from.
    def self.percentile(sorted, pct)
      return 0.0 if sorted.empty?
      rank = (pct / 100.0) * (sorted.size - 1)
      lo = rank.floor
      hi = rank.ceil
      return sorted[lo] if lo == hi
      sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo)
    end

    def percentile(values, pct)
      self.class.percentile(values.sort, pct)
    end

    # Black and white points, taken in display space rather than linear light.
    # In linear the black end is a tiny number and the gamma on the way back
    # re-expands everything just above it, which leaves blacks sitting near 50.
    #
    # Channels share one pair of endpoints by default, which lifts contrast
    # without touching hue. Raising `neutral` moves each channel toward its own
    # endpoints, which is grey-world by another name. See the README for why that
    # is the wrong move on this film.
    def endpoints(black_pct, white_pct, neutral, max_stretch: nil)
      sorted_luma = lumas.sort
      glo = self.class.percentile(sorted_luma, black_pct)
      ghi = self.class.percentile(sorted_luma, white_pct)

      # A frame that already uses very little range is not hiding a good picture
      # inside it. Stretching a 31% frame to full range spreads about 79 source
      # levels over 255 and mostly magnifies grain, so cap how far it goes and
      # let a flat frame stay a little flat.
      if max_stretch && (ghi - glo) < 1.0 / max_stretch
        centre = (glo + ghi) / 2.0
        half = 1.0 / (2.0 * max_stretch)
        glo = [centre - half, 0.0].max
        ghi = [centre + half, 1.0].min
      end

      (0..2).map do |c|
        vals = pixels.map { |px| px[c] }.sort
        clo = self.class.percentile(vals, black_pct)
        chi = self.class.percentile(vals, white_pct)
        [glo + neutral * (clo - glo), ghi + neutral * (chi - ghi)]
      end
    end

    # Anchor points for the tone-dependent balance, as linear luma. Packed toward
    # the dark end because that is where the cast moves fastest and where the eye
    # notices it.
    TONE_ANCHORS = [0.004, 0.012, 0.032, 0.08, 0.18, 0.36, 0.65].freeze

    # How aligned a band's colours must be before it counts as a cast rather
    # than as scene colour, and the least an anchor is ever trusted.
    # How much of the measured correction each anchor actually gets.
    #
    # Shadows take the full amount: down there the film's cast dominates and
    # there is little real colour to lose. Midtones take less, because that is
    # where the subject lives and a cast and warm light are indistinguishable
    # from a single frame. Correcting midtones as hard as shadows pushed them
    # from too red straight through neutral to R/G 0.65.
    ANCHOR_STRENGTH = [0.6, 1.0, 1.0, 0.9, 0.72, 0.65, 0.8].freeze

    COHERENCE_FLOOR = 0.35
    COHERENCE_FULL = 0.80
    MIN_CONFIDENCE = 0.15

    # Measure the cast separately at each tone anchor, rather than once for the
    # whole frame.
    #
    # A single gain cannot fix a cast that changes with brightness, and on some
    # rolls it changes a lot. One Portland roll measures neutral highlights but
    # R/G 1.31 in the midtones and 2.16 in the shadows. Correcting its highlights
    # with a global gain warms everything and drives those midtones further red,
    # which is exactly the wrong direction.
    #
    # Each anchor gets its own gain, measured from the least saturated pixels
    # near that brightness so genuinely coloured subjects do not drag it. The
    # result is a per-channel curve, which is what a tone-dependent cast needs.
    def tone_gains(strength, clamp, shadow_strength = 1.0)
      return nil if strength <= 0
      raw = TONE_ANCHORS.map { |anchor| neutral_at(anchor) }
      return nil if raw.compact.size < 2

      filled = fill_gaps(raw.map { |r| r && r[:mean] })
      confidence = fill_gaps(raw.map { |r| r && r[:confidence] })
      smoothed = smooth(filled)

      smoothed.each_with_index.map do |mean, i|
        s = strength * confidence[i] * ANCHOR_STRENGTH[i]
        s *= shadow_strength if i <= 1
        target = mean.sum / 3.0
        mean.map do |m|
          g = 1.0 + s * (target / [m, 1e-6].max - 1.0)
          g.clamp(1.0 / clamp, clamp)
        end
      end
    end

    # Mean colour of the near-neutral pixels sitting around one brightness, plus
    # how much that reading deserves to be trusted.
    #
    # Confidence asks whether a band's colour is a cast or the scene.
    #
    # Judging that by saturation alone does not work. In the shadows the cast is
    # itself what makes pixels saturated, so treating saturated as untrustworthy
    # throws away the very band most in need of correction. Portland shadows sat
    # at R/G 2.6 for exactly that reason.
    #
    # What separates the two is direction, not amount. A cast pushes every pixel
    # the same way, so their colour vectors line up. Real scene colour points all
    # over: brick one way, foliage another, sky a third. So confidence is the
    # alignment of those vectors, near 1 when a band shares one hue and near 0
    # when it holds many.
    def neutral_at(anchor, width: 0.55, sat_pct: 30, minimum: 400)
      lo = anchor * (1.0 - width)
      hi = anchor * (1.0 + width) + 0.004
      band = pixels.each_with_index
                   .select { |_, i| lumas[i] >= lo && lumas[i] < hi }
                   .map(&:first)
      return nil if band.size < minimum

      sats = band.map { |px| saturation(px) }
      cut = self.class.percentile(sats.sort, sat_pct)
      neutral = band.each_with_index.select { |_, i| sats[i] <= cut }.map(&:first)
      return nil if neutral.size < minimum / 3

      sums = neutral.each_with_object([0.0, 0.0, 0.0]) do |px, acc|
        acc[0] += px[0]
        acc[1] += px[1]
        acc[2] += px[2]
      end
      mean = sums.map { |s| s / neutral.size }

      { mean: mean, confidence: coherence_of(band) }
    end

    # How far a band's colours agree on a direction.
    #
    # Each pixel contributes a chroma vector; if they all point the same way the
    # mean vector is as long as the average individual one and this returns 1.
    # If they cancel out, it returns near 0. The whole band is used rather than
    # the near-grey subset, since the question is about the band as a whole.
    def coherence_of(band)
      sum_r = 0.0
      sum_b = 0.0
      sum_len = 0.0
      count = 0
      band.each do |px|
        y = luma(px)
        next if y <= 1e-6
        dr = (px[0] - y) / y
        db = (px[2] - y) / y
        len = Math.sqrt(dr * dr + db * db)
        next if len < 1e-4
        sum_r += dr
        sum_b += db
        sum_len += len
        count += 1
      end
      return MIN_CONFIDENCE if count < 50 || sum_len <= 1e-6

      aligned = Math.sqrt(sum_r * sum_r + sum_b * sum_b) / sum_len
      ((aligned - COHERENCE_FLOOR) /
       (COHERENCE_FULL - COHERENCE_FLOOR)).clamp(MIN_CONFIDENCE, 1.0)
    end

    # Anchors with too few pixels borrow from their nearest measured neighbour.
    def fill_gaps(values)
      return values if values.all?
      out = values.dup
      out.each_index do |i|
        next if out[i]
        before = (0...i).reverse_each.find { |j| values[j] }
        after = ((i + 1)...out.size).find { |j| values[j] }
        out[i] = (before && values[before]) || (after && values[after])
      end
      out
    end

    # Take the edge off a noisy anchor without flattening the curve.
    #
    # An equal-weight average of three anchors was too much. The whole point here
    # is that shadows and midtones need different corrections, and averaging them
    # together drags the strong shadow gain up into the midtones while diluting
    # it in the shadows, so neither lands. Measured on one Portland frame: the
    # midtones overshot to R/G 0.65 while the shadows stayed at 1.41.
    #
    # So the anchor keeps most of its own measurement and only borrows a little
    # from each side.
    CENTRE_WEIGHT = 0.7

    def smooth(values)
      side = (1.0 - CENTRE_WEIGHT) / 2.0
      values.each_index.map do |i|
        before = values[i - 1] if i.positive?
        after = values[i + 1]
        (0..2).map do |c|
          total = values[i][c] * CENTRE_WEIGHT
          weight = CENTRE_WEIGHT
          if before
            total += before[c] * side
            weight += side
          end
          if after
            total += after[c] * side
            weight += side
          end
          total / weight
        end
      end
    end

    # Mean saturation of the frame as it stands. Rolls differ a lot: the Algarve
    # roll measures 0.27, two Portland rolls from another lab measure 0.37 and
    # 0.41. One fixed multiplier cannot serve both.
    def mean_saturation
      @mean_saturation ||= pixels.sum { |px| saturation(px) } / pixels.size
    end

    # Solve for the vibrance amount that lands this frame on the target
    # saturation, instead of applying a fixed boost and hoping.
    #
    # The knee makes the relationship non-linear, so rather than invert it this
    # bisects on the actual sampled pixels. Twenty rounds is far more than needed
    # and still costs nothing next to reading the file.
    def vibrance_for(target, knee, limit)
      return 1.0 if target <= 0 || pixels.empty?
      lo = 1.0
      hi = limit
      return lo if predicted_saturation(lo, knee) >= target
      return hi if predicted_saturation(hi, knee) <= target
      20.times do
        mid = (lo + hi) / 2.0
        predicted_saturation(mid, knee) < target ? lo = mid : hi = mid
      end
      (lo + hi) / 2.0
    end

    # What the mean saturation would become at this vibrance amount.
    #
    # The boost happens in linear light but the answer is encoded to sRGB before
    # measuring, because saturation means different numbers in the two spaces and
    # the target is a display-space figure. A pixel at linear (0.5, 0.25) reads
    # 0.50 saturated in linear and 0.27 once encoded.
    def predicted_saturation(amount, knee)
      total = 0.0
      pixels.each do |px|
        y = luma(px)
        next if y <= 1e-6
        mx = px.max
        mn = px.min
        ratio = ((mx - mn) / y) / knee
        k = 1.0 + (amount - 1.0) / (1.0 + ratio * ratio)
        hi = encode(y + (mx - y) * k)
        lo = encode(y + (mn - y) * k)
        total += hi <= 1e-6 ? 0.0 : (hi - lo) / hi
      end
      total / pixels.size
    end

    def encode(v)
      return 0.0 if v <= 0.0
      return 1.0 if v >= 1.0
      v <= 0.0031308 ? v * 12.92 : 1.055 * (v**(1 / 2.4)) - 0.055
    end

  end
end
