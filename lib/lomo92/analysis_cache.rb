require "yaml"
require "digest"

module Lomo92
  # Remembers a roll's colour fit so it is only computed once.
  #
  # Sampling a whole roll and solving for its gamut is not cheap, and nothing
  # about a roll changes between runs, so the result is kept next to the output
  # and reused until something it depends on changes.
  #
  # What it depends on is the source files and the code that measures them, so
  # both are in the key. Each file contributes its path, size and modification
  # time, and the fitting code contributes a digest of its own source. That last
  # part matters more than it looks: without it, changing how the fit works would
  # quietly keep serving the old answer, and every comparison afterwards would be
  # against a result the current code never produced.
  #
  # The stored gains are the raw fit, before --roll-profile scales them, so
  # changing that setting reuses the fit rather than recomputing it.
  module AnalysisCache
    module_function

    VERSION = 2

    SOURCES = %w[gamut_fit.rb roll_sample.rb].freeze

    def key(paths)
      files = paths.sort.map do |p|
        stat = File.stat(p)
        "#{p}:#{stat.size}:#{stat.mtime.to_i}"
      end
      code = SOURCES.map do |name|
        Digest::SHA256.file(File.join(__dir__, name)).hexdigest
      end
      Digest::SHA256.hexdigest([VERSION, *code, *files].join("\n"))
    end

    def path(destination)
      File.join(destination, "roll-fit.yml")
    end

    def load(destination, key)
      file = path(destination)
      return nil unless File.exist?(file)

      data = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false,
                                               symbolize_names: true)
      return nil unless data.is_a?(Hash) && data[:key] == key

      data
    rescue Psych::Error, SystemCallError
      nil
    end

    def save(destination, key, fit)
      File.write(path(destination), YAML.dump(
        "key" => key,
        "gains" => fit.gains,
        "clipped" => fit.clipped,
        "spread_before" => fit.spread_before,
        "spread_after" => fit.spread_after
      ))
    rescue SystemCallError
      # A cache that cannot be written is not worth failing a render over.
      nil
    end
  end
end
