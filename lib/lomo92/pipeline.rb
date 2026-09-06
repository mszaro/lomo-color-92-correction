module Lomo92
  # The correction itself.
  #
  # Order:
  #   white balance -> vibrance -> white balance -> endpoints -> contrast -> denoise
  #
  # The order is not arbitrary and most of it was arrived at by getting it wrong
  # first. See the README for the measurements behind each step.
  class Pipeline
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    # A second balancing pass after vibrance, applied gently. At full strength
    # it doubles up on the first and pushes corrected bands past neutral.
    SECOND_PASS = 0.35

    def initialize(options, roll_profile = nil)
      @o = options
      @roll = roll_profile
    end

    def call(path)
      srgb_in = Colour.load(path)

      # Pass one: undo what this roll's scan got wrong. Estimated once across
      # every frame, so it carries no assumption about any single picture.
      srgb_in = apply_roll_profile(srgb_in)

      linear = Colour.to_linear(srgb_in)

      # Colour work is measured and applied in linear light, where a gain is
      # what it claims to be. Tone work happens later in display space instead.
      measured = Measurements.new(linear)

      # Balance before the vibrance boost, since vibrance scales distance from
      # grey and would multiply any cast along with the colour we actually want.
      # Pass two: this frame's own character. The roll profile has already taken
      # out the systematic error, so what remains is lighting and subject, and
      # this only needs to nudge rather than rebuild.
      linear = apply_tone_gains(linear, measured.tone_gains(@o[:wb], @o[:wb_clamp],
                                                            @o[:shadow_wb]))
      linear = vibrance(linear, vibrance_amount(measured), @o[:knee])

      # And balance again afterwards. Vibrance lifts low-chroma pixels hardest,
      # which is exactly where leftover cast sits, so one pass beforehand leaves
      # an error the boost then amplifies. Doing both roughly halves the
      # frame-to-frame spread; doing only one made it worse than not doing it.
      after = Measurements.new(linear)
      linear = apply_tone_gains(linear, after.tone_gains(@o[:wb] * SECOND_PASS,
                                                         @o[:wb_clamp], @o[:shadow_wb]))

      srgb = Colour.to_srgb(linear)
      points = Measurements.new(srgb).endpoints(@o[:black], @o[:white], @o[:neutral],
                                                max_stretch: @o[:max_stretch])
      srgb = apply_endpoints(srgb, points)
      srgb = s_curve(srgb, @o[:contrast])
      denoise_chroma(srgb, @o[:chroma], chroma_radius_for(srgb))
    end

    private

    def apply_roll_profile(srgb)
      return srgb unless @roll
      luts = @roll.vips_luts
      index = (Colour.clamp01(srgb) * 255.0).cast(:uchar)
      bands = (0..2).map { |c| index[c].maplut(luts[c]) }
      rejoin(bands)
    end

    # Rebuilding an image band by band loses the sRGB tag, and vips then writes
    # the file as greyscale however many bands it has. Put the tag back.
    def rejoin(bands)
      bands[0].bandjoin([bands[1], bands[2]]).copy(interpretation: :srgb)
    end

    # Either a fixed boost, or solve per frame for the target saturation. The
    # second is the default because rolls arrive at very different starting
    # points and a single number cannot suit all of them.
    def vibrance_amount(measured)
      return @o[:saturation] if @o[:saturation]
      measured.vibrance_for(@o[:target_saturation], @o[:knee], @o[:max_vibrance])
    end

    # Apply the per-anchor gains as a curve indexed by brightness.
    #
    # Each channel gets a 256-entry lookup built by interpolating between the
    # anchors, then every pixel is scaled by whatever its own luma looks up.
    # That gives a per-channel curve instead of a flat multiplier, so a frame
    # whose shadows and highlights are cast in different directions can have
    # both corrected at once.
    def apply_tone_gains(image, gains)
      return image unless gains
      y = luma_of(image)

      # Blur the luma before looking anything up. Grain is high-frequency luma,
      # so indexing on a pixel's own value makes a bright speck and its dark
      # neighbour read different points on the curve and come back different
      # colours. That turns luma noise into colour noise, which showed up as
      # warm grain sitting on a cooled base. The cast follows scene brightness,
      # not individual grains.
      guide = y.gaussblur(2.0)

      # The index is sRGB-encoded, matching how build_curve fills each entry.
      # Indexing on linear luma while filling by sRGB reads the curve at the
      # wrong place entirely: a treeline at linear 0.054 was picking up the gain
      # meant for 0.004, a band four stops darker.
      index = (Colour.to_srgb(guide) * 255.0).cast(:uchar)
      bands = (0..2).map do |c|
        lut = Vips::Image.new_from_array([build_curve(gains, c)])
        image[c] * index.maplut(lut)
      end
      rejoin(bands)
    end

    # Expand the handful of anchor gains into one entry per possible luma value,
    # interpolating in the same linear light the anchors were measured in.
    def build_curve(gains, channel)
      anchors = Measurements::TONE_ANCHORS
      (0..255).map do |i|
        y = Colour.srgb_to_linear_scalar(i / 255.0)
        if y <= anchors.first
          gains.first[channel]
        elsif y >= anchors.last
          gains.last[channel]
        else
          hi = anchors.index { |a| a >= y }
          lo = hi - 1
          span = anchors[hi] - anchors[lo]
          t = span.zero? ? 0.0 : (y - anchors[lo]) / span
          gains[lo][channel] * (1 - t) + gains[hi][channel] * t
        end
      end
    end

    # Vibrance, not flat saturation. These scans are bleached, so washed out
    # midtones need real help, but a flat multiplier drags anything that kept its
    # colour past plausible. Dry grass going orange was this, not a colour cast.
    # The boost is strongest near grey and halves at the knee.
    def vibrance(image, amount, knee)
      return image if amount == 1.0
      y = luma_of(image)
      r, g, b = image[0], image[1], image[2]
      mx = (r > g).ifthenelse(r, g)
      mx = (mx > b).ifthenelse(mx, b)
      mn = (r < g).ifthenelse(r, g)
      mn = (mn < b).ifthenelse(mn, b)
      safe_y = (y < 1e-6).ifthenelse(1e-6, y)
      ratio = ((mx - mn) / safe_y) / knee
      k = (ratio * ratio + 1.0)**-1.0 * (amount - 1.0) + 1.0
      (image - y) * k + y
    end

    def apply_endpoints(image, points)
      lo = points.map(&:first)
      span = points.map { |p| [p[1] - p[0], 1e-6].max }
      Colour.clamp01((image - lo) / span)
    end

    # Contrast around mid grey. The minus matters: sin is positive below mid
    # grey, so adding it would lift shadows and flatten the picture instead.
    def s_curve(image, amount)
      return image if amount <= 0
      k = amount / (2.0 * Math::PI)
      # vips sin() takes degrees, so scale the turn to 360 rather than 2*pi.
      Colour.clamp01(image - (image * 360.0).sin * k)
    end

    # Blur the colour difference from luma and leave luma alone, so film grain
    # and detail survive while colour speckle goes.
    #
    # Two scales. Residual chroma noise keeps climbing out to a radius of 32,
    # meaning the fine speckle sits on much larger colour blotches that a small
    # radius misses. The coarse pass is gentler because a wide blur will bleed
    # colour across edges if you lean on it.
    def denoise_chroma(image, amount, radius)
      return image if amount <= 0
      y = luma_of(image)
      diff = image - y
      # Gaussian standing in for a box blur of the given radius. Matching on
      # variance keeps the strength the same: a box of width 2r+1 has the same
      # spread as a gaussian of sigma (2r+1)/sqrt(12).
      fine = diff.gaussblur(sigma_for(radius))
      coarse = fine.gaussblur(sigma_for(radius * 3))
      d = diff * (1.0 - amount) + fine * amount
      d = d * (1.0 - amount * 0.55) + coarse * (amount * 0.55)
      Colour.clamp01(d + y)
    end

    # Grain covers fewer pixels in a smaller scan, so a radius tuned on a 6144
    # wide file smears colour on a half-size one. Scale with width unless told.
    def chroma_radius_for(image)
      return @o[:chroma_radius] if @o[:chroma_radius]
      [(5.0 * image.width / 6144.0).round, 2].max
    end

    def sigma_for(radius)
      (2 * radius + 1) / Math.sqrt(12)
    end

    def luma_of(image)
      (image * LUMA).bandmean * 3.0
    end
  end
end
