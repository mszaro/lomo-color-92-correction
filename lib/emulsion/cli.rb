require "optparse"
require "fileutils"
require "yaml"

module Emulsion
  # Command line front end. Corrects every scan in a folder and writes the
  # results to a sibling folder, leaving the originals untouched.
  class CLI
    EXTENSIONS = %w[tif tiff TIF TIFF jpg jpeg JPG JPEG png PNG].freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      flags = { previews: false }
      parser = build_parser(flags)
      parser.parse!(argv)

      source = argv.shift
      unless source
        warn parser
        return 1
      end
      unless flags[:profile]
        warn "which film is this? Pass --profile, one of: #{Profile.available.join(', ')}"
        return 1
      end

      begin
        profile = Profile.load(flags[:profile])
      rescue ArgumentError => e
        warn e.message
        return 1
      end
      # The profile sets the picture, and anything given on the command line wins.
      options = DEFAULTS.merge(profile.settings).merge(flags)

      source = File.expand_path(source)
      unless File.directory?(source)
        warn "not a directory: #{source}"
        return 1
      end

      destination = options[:out] ? File.expand_path(options[:out])
                                  : "#{source.chomp('/')} - corrected"
      if destination == source
        warn "refusing to write into the source directory"
        return 1
      end

      files = find_files(source, options[:only])
      if files.empty?
        warn "no images matching #{options[:only] || '*'} in #{source}"
        return 1
      end

      FileUtils.mkdir_p(destination)
      preview_dir = File.join(destination, "preview")
      FileUtils.mkdir_p(preview_dir) if options[:previews]

      overrides = load_overrides(options[:overrides])
      puts "profile: #{profile.name}"

      # The roll is fitted once, across every frame, before any frame is written.
      roll = nil
      if options[:roll_fit].positive?
        all = find_files(source, nil)
        key = AnalysisCache.key(all, profile.healthy_spread)
        cached = AnalysisCache.load(destination, key)
        if cached
          puts "reusing the colour fit for this roll"
          roll = GamutFit.from_cache(cached)
        else
          puts "sampling roll of #{all.size} frames..."
          samples = RollSample.collect(all)
          puts "fitting colour to reopen the roll's gamut..."
          roll = GamutFit.new(samples, healthy_spread: profile.healthy_spread)
          AnalysisCache.save(destination, key, roll)
        end
        roll.strength = options[:roll_fit]
        puts roll.report
      end

      puts "processing #{files.size} frames -> #{destination}"
      files.each_with_index do |path, i|
        name = File.basename(path)
        stem = File.basename(name, ".*")
        frame_options = options.merge(overrides[stem] || {})
        result = Pipeline.new(frame_options, roll).call(path)
        # Render once into memory when a preview is wanted too. Shrinking the
        # unrendered pipeline for the preview ran all of it again, and on a
        # 6144px frame that took 45GB.
        result = result.copy_memory if options[:previews]
        written = write_result(result, destination, stem, path, options)
        if options[:previews]
          jpeg = File.join(preview_dir, "#{stem}.jpg")
          (result * 255).cast(:uchar).thumbnail_image(1600, size: :down)
                        .jpegsave(jpeg, Q: 92)
        end
        puts "  [#{i + 1}/#{files.size}] #{name} -> #{File.basename(written)}"
      end

      File.write(File.join(destination, "settings.yml"),
                 YAML.dump(options.transform_keys(&:to_s)))
      puts "done"
      0
    end

    private

    # TIFF and PNG are written at 16 bits, even from an 8-bit scan, so later
    # edits do not turn the stretched levels into banding. JPEG is always 8-bit;
    # quality 98 measures 45.8 dB against the 16-bit render, where 95 gives 40.7.
    FORMATS = {
      "tiff" => ".tiff", "tif" => ".tiff",
      "jpeg" => ".jpg", "jpg" => ".jpg",
      "png" => ".png"
    }.freeze

    # Match the input unless told otherwise, so a JPEG scan comes back a JPEG.
    def output_format(source_path, options)
      return options[:format] if options[:format]

      case File.extname(source_path).downcase
      when ".jpg", ".jpeg" then "jpeg"
      when ".png" then "png"
      else "tiff"
      end
    end

    # Written under a temporary name and renamed when complete, so an
    # interrupted run never leaves a truncated file that looks finished.
    def write_result(result, destination, stem, source_path, options)
      format = output_format(source_path, options)
      path = File.join(destination, stem + FORMATS.fetch(format))
      partial = "#{path}.partial"

      case format
      when "jpeg"
        # 4:4:4, because chroma subsampling smears grain into coloured blocks.
        (result * 255).cast(:uchar)
          .jpegsave(partial, Q: options[:quality], subsample_mode: :off,
                             optimize_coding: true)
      when "png"
        (result * 65535).cast(:ushort).pngsave(partial, compression: 6)
      else
        (result * 65535).cast(:ushort).tiffsave(partial, compression: :lzw)
      end
      File.rename(partial, path)
      path
    ensure
      File.delete(partial) if partial && File.exist?(partial)
    end

    # Per-frame overrides, keyed by filename without extension. Values use the
    # long option names, so "saturation: 1.6" under "000057".
    def load_overrides(path)
      return {} unless path
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      raise "overrides file must be a mapping of frame name to settings" unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(frame, settings), acc|
        acc[frame.to_s] = settings.transform_keys { |k| k.to_s.tr("-", "_").to_sym }
      end
    end

    def find_files(source, only)
      pattern = only || "*"
      EXTENSIONS.flat_map { |ext| Dir.glob(File.join(source, "#{pattern}.#{ext}")) }
                .uniq.sort
    end

    def build_parser(options)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Correct lab scans of film stocks the scanner had no profile for.

          Usage: emulsion --profile NAME [options] SOURCE_DIR

          Writes corrected frames to "SOURCE_DIR - corrected", in the same format
          they came in as. Originals are never modified. The profile sets the
          colour, tone and grain settings below; any you pass override it.
        BANNER

        opts.separator ""
        opts.on("-p", "--profile NAME",
                "Film stock: #{Profile.available.join(', ')},",
                "or the path to a profile YAML file of your own.") { |v| options[:profile] = v }

        opts.separator ""
        opts.separator "Colour:"
        opts.on("--target-saturation FLOAT", Float,
                "Boost each frame toward this mean saturation.") { |v| options[:target_saturation] = v }
        opts.on("-S", "--saturation FLOAT", Float,
                "Fixed vibrance for every frame instead of a target.") { |v| options[:saturation] = v }
        opts.on("--max-vibrance FLOAT", Float,
                "Ceiling on the vibrance boost.") { |v| options[:max_vibrance] = v }
        opts.on("--knee FLOAT", Float,
                "Chroma at which the boost halves. Lower protects colourful subjects.") { |v| options[:knee] = v }
        opts.on("--roll-fit FLOAT", Float,
                "Strength of the whole-roll colour fit, 0 to 1 (default #{DEFAULTS[:roll_fit]}).",
                "A roll that is already healthy fits to no change.") { |v| options[:roll_fit] = v }
        opts.on("-w", "--wb FLOAT", Float,
                "Per-frame white balance strength, 0 to 1. 0 disables it.") { |v| options[:wb] = v }
        opts.on("--wb-clamp FLOAT", Float,
                "Cap on any single channel gain.") { |v| options[:wb_clamp] = v }
        opts.on("--shadow-wb FLOAT", Float,
                "Strength of the separate shadow balance.") { |v| options[:shadow_wb] = v }
        opts.on("-n", "--neutral FLOAT", Float,
                "Grey-world share, 0 to 1. Usually best left at 0.") { |v| options[:neutral] = v }

        opts.separator ""
        opts.separator "Tone:"
        opts.on("-t", "--contrast FLOAT", Float, "S-curve amount.") { |v| options[:contrast] = v }
        opts.on("--black FLOAT", Float, "Black clip percentile.") { |v| options[:black] = v }
        opts.on("--white FLOAT", Float, "White clip percentile.") { |v| options[:white] = v }
        opts.on("--max-stretch FLOAT", Float,
                "Most a frame's range may be stretched, so a very flat",
                "frame can stay a little flat rather than magnify grain.") { |v| options[:max_stretch] = v }

        opts.separator ""
        opts.separator "Grain:"
        opts.on("-c", "--chroma FLOAT", Float,
                "Colour noise reduction, 0 to 1. Luma grain is left alone.") { |v| options[:chroma] = v }
        opts.on("-R", "--chroma-radius INT", Integer,
                "Colour blur radius in pixels. Scales with image width by default.") { |v| options[:chroma_radius] = v }

        opts.separator ""
        opts.separator "Output:"
        opts.on("-o", "--out DIR", "Destination directory.") { |v| options[:out] = v }
        opts.on("-f", "--format FORMAT", FORMATS.keys,
                "Output format: tiff, jpeg or png. Defaults to the input's.") { |v| options[:format] = v }
        opts.on("--quality N", Integer,
                "JPEG quality (default #{DEFAULTS[:quality]}). Always 4:4:4.") { |v| options[:quality] = v }
        opts.on("--previews", "--jpeg", "Also write 1600px preview JPEGs.") { |v| options[:previews] = v }
        opts.on("--only GLOB", "Filter frames, for example '0000[45]*'.") { |v| options[:only] = v }
        opts.on("--overrides FILE", "YAML of per-frame settings, keyed by filename",
                "without extension.") { |v| options[:overrides] = v }

        opts.separator ""
        opts.on("-h", "--help", "Show this message.") do
          puts opts
          exit 0
        end
        opts.on("-v", "--version", "Show version.") do
          puts Emulsion::VERSION
          exit 0
        end
      end
    end
  end
end
