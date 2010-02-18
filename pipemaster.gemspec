Gem::Specification.new do |spec|
  spec.name           = "pipemaster"
  spec.version        = "0.1.0"
  spec.author         = "Assaf Arkin"
  spec.email          = "assaf@labnotes.org"
  spec.homepage       = "http://labnotes.org"
  spec.summary        = "Use the fork"
  spec.post_install_message = "To get started run pipemaster --help"

  spec.files          = Dir["{bin,lib,test}/**/*", "CHANGELOG", "LICENSE", "README.rdoc", "Rakefile", "Gemfile", "pipemaster.gemspec"]
  spec.executable     = "pipemaster"

  spec.has_rdoc         = true
  spec.extra_rdoc_files = "README.rdoc", "CHANGELOG"
  spec.rdoc_options     = "--title", "Pipemaster #{spec.version}", "--main", "README.rdoc",
                          "--webcvs", "http://github.com/assaf/#{spec.name}"
end
