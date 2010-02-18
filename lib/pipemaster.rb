module Pipemaster
  # Version number.
  VERSION = Gem::Specification.load(File.expand_path("../pipemaster.gemspec", File.dirname(__FILE__))).version.to_s

  DEFAULT_HOST = "127.0.0.1"
  DEFAULT_PORT = 7887
  DEFAULT_LISTEN = "#{DEFAULT_HOST}:#{DEFAULT_PORT}"
end
