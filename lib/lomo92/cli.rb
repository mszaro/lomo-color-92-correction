require "optparse"
require "fileutils"
require "json"
require "yaml"

module Lomo92
  # Command line front end. Walks a directory of TIFFs and writes corrected
  # copies to a sibling directory, leaving the originals untouched.
  class CLI
    EXTENSIONS = %w[tif tiff TIF TIFF jpg jpeg JPG JPEG png PNG].freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      options = Lomo92::DEFAULTS.dup
      options[:out] = nil
      options[:jpeg] = false
      options[:only] = nil
      options[:overrides] = nil

      parser = build_parser(options)
      parser.parse!(argv)

      source = argv.shift
      unless source
        warn parser
        return 1
      end

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
      FileUtils.mkdir_p(preview_dir) if options[:jpeg]

      overrides = load_overrides(options[:overrides])

      # Pass one runs over the whole roll before any frame is written, so every
      # frame is corrected against the same understanding of the scan.
      roll = nil
      if options[:roll_profile].positive?
        all = find_files(source, nil)
        puts "profiling roll from #{all.size} frames..."
        roll = RollProfile.new(all, strength: options[:roll_profile])
        puts roll.report
      end

      puts "processing #{files.size} frames -> #{destination}"
      files.each_with_index do |path, i|
        name = File.basename(path)
        stem_key = File.basename(name, ".*")
        # A handful of frames on any roll want their own settings. Usually the
        # very flat or very dark ones, where stretching to full range does more
        # harm than leaving them a bit low-key.
        frame_options = options.merge(overrides[stem_key] || {})
        result = Pipeline.new(frame_options, roll).call(path)
        stem = File.basename(name, ".*")
        # The pipeline works in float 0..1, so scale up rather than bit-shift.
        (result * 65535).cast(:ushort).tiffsave(File.join(destination, "#{stem}.tiff"),
                                                compression: :lzw)
        if options[:jpeg]
          jpeg = File.join(preview_dir, "#{stem}.jpg")
          (result * 255).cast(:uchar).thumbnail_image(1600, size: :down)
                        .jpegsave(jpeg, Q: 92)
        end
        puts "  [#{i + 1}/#{files.size}] #{name}"
      end

      File.write(File.join(destination, "settings.json"), JSON.pretty_generate(options))
      puts "done"
      0
    end

    private

    # Per-frame overrides, keyed by filename without extension. Values are the
    # same names as the long options, so "saturation: 1.6" under "000057".
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
          Re-balance flat, bleached lab scans of Lomography LomoChrome Color '92.

          Usage: lomo92fix [options] SOURCE_DIR

          Writes 16-bit TIFFs to "SOURCE_DIR - corrected" unless told otherwise.
          Originals are never modified.
        BANNER

        opts.separator ""
        opts.separator "Colour:"
        opts.on("--target-saturation FLOAT", Float,
                "Aim each frame at this mean saturation (default #{options[:target_saturation]}).",
                "Solved per frame, so rolls that arrive more or less bleached",
                "than each other all land in the same place.") { |v| options[:target_saturation] = v }
        opts.on("-S", "--saturation FLOAT", Float,
                "Fixed vibrance strength instead of solving for a target.",
                "Overrides --target-saturation for every frame.") { |v| options[:saturation] = v }
        opts.on("--max-vibrance FLOAT", Float,
                "Ceiling on the solved vibrance (default #{options[:max_vibrance]}).") { |v| options[:max_vibrance] = v }
        opts.on("--knee FLOAT", Float,
                "Chroma at which the vibrance boost halves (default #{options[:knee]}).",
                "Lower values protect already-colourful subjects more.") { |v| options[:knee] = v }
        opts.on("--roll-profile FLOAT", Float,
                "Strength of the whole-roll scan correction, 0-1 (default #{options[:roll_profile]}).",
                "Measured once across every frame, so scene colour cancels and",
                "the scan error is what is left. 0 disables it.") { |v| options[:roll_profile] = v }
        opts.on("-w", "--wb FLOAT", Float,
                "Per-frame white balance strength, 0 to 1 (default #{options[:wb]}).",
                "Measured from bright near-neutral pixels. 0 disables it.") { |v| options[:wb] = v }
        opts.on("--wb-clamp FLOAT", Float,
                "Cap on any single channel gain (default #{options[:wb_clamp]}).",
                "Stops a failed estimate from wrecking a frame.") { |v| options[:wb_clamp] = v }
        opts.on("--shadow-wb FLOAT", Float,
                "Second grey balance point for the shadows (default #{options[:shadow_wb]}).",
                "Balancing highlights alone leaves this film's shadows yellow.") { |v| options[:shadow_wb] = v }
        opts.on("-n", "--neutral FLOAT", Float,
                "Per-channel endpoint share, 0 to 1 (default #{options[:neutral]}).",
                "This is grey-world. Leave it at 0: the whites on this stock",
                "already measure neutral, so raising it introduces a cast.") { |v| options[:neutral] = v }

        opts.separator ""
        opts.separator "Tone:"
        opts.on("-t", "--contrast FLOAT", Float,
                "S-curve amount (default #{options[:contrast]}).") { |v| options[:contrast] = v }
        opts.on("--black FLOAT", Float,
                "Black clip percentile (default #{options[:black]}).") { |v| options[:black] = v }
        opts.on("--white FLOAT", Float,
                "White clip percentile (default #{options[:white]}).") { |v| options[:white] = v }
        opts.on("--max-stretch FLOAT", Float,
                "Most a frame's range may be stretched (default #{options[:max_stretch]}).",
                "A very flat frame stretched to full range mostly magnifies",
                "grain, so this lets one stay a little flat instead.") { |v| options[:max_stretch] = v }

        opts.separator ""
        opts.separator "Grain:"
        opts.on("-c", "--chroma FLOAT", Float,
                "Chroma noise reduction, 0 to 1 (default #{options[:chroma]}).",
                "Blurs colour only. Luma grain is left alone on purpose.") { |v| options[:chroma] = v }
        opts.on("-R", "--chroma-radius INT", Integer,
                "Chroma blur radius in pixels.",
                "Defaults to scaling with image width, 5px at 6144 wide,",
                "since grain occupies fewer pixels in a smaller scan.") { |v| options[:chroma_radius] = v }

        opts.separator ""
        opts.separator "Output:"
        opts.on("-o", "--out DIR", "Destination directory.") { |v| options[:out] = v }
        opts.on("--jpeg", "Also write 1600px preview JPEGs.") { |v| options[:jpeg] = v }
        opts.on("--only GLOB", "Filter frames, for example '0000[45]*'.") { |v| options[:only] = v }
        opts.on("--overrides FILE", "YAML or JSON of per-frame setting overrides,",
                "keyed by filename without extension. See the README.") { |v| options[:overrides] = v }

        opts.separator ""
        opts.on("-h", "--help", "Show this message.") do
          puts opts
          exit 0
        end
        opts.on("-v", "--version", "Show version.") do
          puts Lomo92::VERSION
          exit 0
        end
      end
    end
  end
end
