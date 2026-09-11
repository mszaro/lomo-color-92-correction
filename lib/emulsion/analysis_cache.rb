require "yaml"
require "digest"

module Emulsion
  # Remembers a roll's colour fit, kept next to the output as roll-fit.yml.
  #
  # The key covers everything the fit depends on: each source file's path, size
  # and time, the profile's healthy spread, and a digest of the fitting code, so
  # changing how the fit works never quietly serves an old answer.
  module AnalysisCache
    module_function

    VERSION = 3

    SOURCES = %w[gamut_fit.rb roll_sample.rb].freeze

    def key(paths, healthy_spread)
      files = paths.sort.map do |p|
        stat = File.stat(p)
        "#{p}:#{stat.size}:#{stat.mtime.to_i}"
      end
      code = SOURCES.map do |name|
        Digest::SHA256.file(File.join(__dir__, name)).hexdigest
      end
      Digest::SHA256.hexdigest([VERSION, healthy_spread, *code, *files].join("\n"))
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
    rescue Psych::Exception, SystemCallError
      nil
    end

    # The stored gains are the raw fit, before --roll-fit scales them, so
    # changing the strength reuses the fit.
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
