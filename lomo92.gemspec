require_relative "lib/lomo92/version"

Gem::Specification.new do |spec|
  spec.name = "lomo92"
  spec.version = Lomo92::VERSION
  spec.authors = ["mszaro"]
  spec.summary = "Re-balance flat, bleached lab scans of Lomography LomoChrome Color '92"
  spec.description = <<~TEXT
    Lab scans of LomoChrome Color '92 come back with no black point, no white
    point and collapsed colour. This restores the tonal range and chroma without
    the grey-world white balance that makes the apparent cast worse.
  TEXT
  spec.homepage = "https://github.com/mszaro/lomo-color-92-correction"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "bin/*", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["lomo92fix"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby-vips", "~> 2.2"
end
