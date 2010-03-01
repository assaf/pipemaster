Gem::Specification.new do |spec|
  spec.name           = "pipemaster"
  spec.version        = "0.5.1"
  spec.author         = "Assaf Arkin"
  spec.email          = "assaf@labnotes.org"
  spec.homepage       = "http://github.com/assaf/pipemaster"
  spec.summary        = "Use the fork"
  spec.post_install_message = "To get started run pipemaster --help"

  spec.files          = Dir["{bin,lib,test,etc}/**/*", "CHANGELOG", "LICENSE", "README.rdoc", "Rakefile", "Gemfile", "pipemaster.gemspec"]
  spec.executables    = %w{pipe pipemaster}

  spec.has_rdoc         = true
  spec.extra_rdoc_files = "README.rdoc", "CHANGELOG"
  spec.rdoc_options     = "--title", "Pipemaster #{spec.version}", "--main", "README.rdoc",
                          "--webcvs", "http://github.com/assaf/#{spec.name}"
end
