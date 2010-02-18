require "unicorn/launcher"
require "pipemaster/configurator"
require "pipemaster/worker"
require "pipemaster/server"

module Pipemaster
  VERSION = Gem::Specification.load(File.expand_path("../pipemaster.gemspec", File.dirname(__FILE__))).version.to_s
end
