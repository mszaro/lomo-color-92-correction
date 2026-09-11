module Lomo92
  # A representative handful of pixels from every frame in a roll.
  #
  # The gamut fit needs to evaluate its objective hundreds of times, which rules
  # out touching the images each round. Instead the roll is reduced once to a
  # bag of pixels and the fit works on that.
  #
  # Sampling is by stride rather than by scaling. Scaling averages neighbours,
  # which pulls the extremes toward the middle and would quietly narrow the very
  # distribution being measured. Taking every Nth pixel leaves the distribution
  # alone and simply holds less of it.
  class RollSample
    LUMA = [0.2126, 0.7152, 0.0722].freeze
    INSET = 0.05

    def self.collect(paths, per_frame: 6000, verbose: true)
      r = []
      g = []
      b = []
      y = []

      paths.each_with_index do |path, i|
        print "\r  sampling #{i + 1}/#{paths.size}" if verbose
        image = Vips::Image.new_from_file(path, access: :random)
        image = image.bandjoin([image, image]) if image.bands == 1
        image = image[0..2] if image.bands > 3
        image = image.cast(:float)
        image /= 257.0 if image.max > 256

        w = image.width
        h = image.height
        dx = (w * INSET).to_i
        dy = (h * INSET).to_i
        inner = image.extract_area(dx, dy, w - 2 * dx, h - 2 * dy)

        factor = Math.sqrt(inner.width * inner.height / per_frame.to_f).floor
        inner = inner.subsample(factor, factor) if factor > 1

        raw = inner.cast(:float).write_to_memory.unpack("f*")
        raw.each_slice(inner.bands) do |px|
          r << px[0]
          g << px[1]
          b << px[2]
          y << (LUMA[0] * px[0] + LUMA[1] * px[1] + LUMA[2] * px[2])
        end
      end
      puts if verbose
      [r, g, b, y]
    end
  end
end
