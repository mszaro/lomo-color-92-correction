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

    # Estimate the frame's colour cast from bright, nearly grey pixels: white
    # walls, pale stone, cloud.
    #
    # Bright on its own would fail. On a frame that is mostly sky the brightest
    # pixels are the sky, and neutralising those would bleach it. Keeping only
    # the least saturated of the bright set finds the white-ish things and steps
    # over saturated ones. That is what makes this safer than grey-world here: it
    # never assumes the scene averages grey, only that something white is in
    # shot. A frame offering no such reference gets left alone.
    def highlight_gains(strength, clamp)
      return nil if strength <= 0
      cut = self.class.percentile(lumas.sort, 85)
      bright = pixels.each_with_index
                     .select { |px, i| lumas[i] >= cut && px.max < 0.97 }
                     .map(&:first)
      return nil if bright.size < 300
      gains_from_neutral(bright, 40, 150, strength, clamp)
    end

    # Balancing the highlights leaves the shadows where the film put them, and on
    # this stock that is strongly yellow. Mid-shadow B/G measures 0.36 to 0.84 on
    # the worst frames, where open shade lit by blue sky should sit above 1.0.
    #
    # Correcting a dark point as well as a bright one makes this a two-point grey
    # balance, which is a per-channel curve rather than one flat gain. That is
    # the only thing that can fix a cast which differs between shadows and
    # highlights, and it is why white balance sliders never quite land on these.
    def shadow_gains(strength, clamp = 1.8, ceiling = 0.16)
      return nil if strength <= 0
      band = pixels.each_with_index
                   .select { |_, i| lumas[i] > 0.006 && lumas[i] < ceiling }
                   .map(&:first)
      return nil if band.size < 500
      gains_from_neutral(band, 60, 250, strength, clamp)
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

    private

    def gains_from_neutral(candidates, sat_pct, minimum, strength, clamp)
      sats = candidates.map { |px| saturation(px) }
      cut = self.class.percentile(sats.sort, sat_pct)
      neutral = candidates.each_with_index.select { |_, i| sats[i] <= cut }.map(&:first)
      return nil if neutral.size < minimum

      sums = neutral.each_with_object([0.0, 0.0, 0.0]) do |px, acc|
        acc[0] += px[0]
        acc[1] += px[1]
        acc[2] += px[2]
      end
      mean = sums.map { |s| s / neutral.size }
      target = mean.sum / 3.0

      # The clamp earns its keep. A real cast runs a few percent; anything wilder
      # means the estimator locked onto something coloured rather than a neutral.
      # One frame on the reference roll asks for 2.4x on red. Clamping leaves it
      # under-corrected instead of ruined.
      mean.map do |m|
        g = 1.0 + strength * (target / [m, 1e-6].max - 1.0)
        g.clamp(1.0 / clamp, clamp)
      end
    end
  end
end
