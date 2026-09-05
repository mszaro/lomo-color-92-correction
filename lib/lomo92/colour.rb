module Lomo92
  # sRGB transfer curves, written out rather than using colourspace(:srgb).
  #
  # libvips treats sRGB as 8-bit 0..255 and scRGB as float 0..1, so converting
  # between them quantises and changes the numeric range under you. Everything
  # here stays float 0..1 from load to save, which keeps the maths honest and
  # avoids rounding to 8 bits in the middle of a pipeline that is stretching
  # tones apart.
  module Colour
    module_function

    def to_linear(image)
      low = image / 12.92
      high = ((image + 0.055) / 1.055)**2.4
      (image <= 0.04045).ifthenelse(low, high)
    end

    def to_srgb(image)
      image = clamp01(image)
      low = image * 12.92
      high = (image**(1 / 2.4)) * 1.055 - 0.055
      clamp01((image <= 0.0031308).ifthenelse(low, high))
    end

    # Scalar version, for building lookup tables in plain Ruby.
    def srgb_to_linear_scalar(v)
      v <= 0.04045 ? v / 12.92 : (((v + 0.055) / 1.055)**2.4)
    end

    def clamp01(image)
      image = (image < 0).ifthenelse(0, image)
      (image > 1).ifthenelse(1, image)
    end

    # Load as float 0..1 sRGB. Alpha and extra bands are dropped; a greyscale
    # scan gets fanned out to three channels so the rest of the code is uniform.
    def load(path)
      image = Vips::Image.new_from_file(path, access: :random)
      image = image.bandjoin([image, image]) if image.bands == 1
      image = image[0..2] if image.bands > 3
      image.cast(:float) / 255.0
    end
  end
end
