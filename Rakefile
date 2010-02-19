require "rake/testtask"

spec = Gem::Specification.load(File.expand_path("pipemaster.gemspec", File.dirname(__FILE__)))

desc "Push new release to gemcutter and git tag"
task :push do
  sh "git push"
  puts "Tagging version #{spec.version} .."
  sh "git tag v#{spec.version}"
  sh "git push --tag"
  puts "Building and pushing gem .."
  sh "gem build #{spec.name}.gemspec"
  sh "gem push #{spec.name}-#{spec.version}.gem"
end

desc "Build #{spec.name}-#{spec.version}.gem"
task :build=>:test do
  sh "gem build #{spec.name}.gemspec"
end

desc "Install #{spec.name} locally"
task :install=>:build do
  sudo = "sudo" unless File.writable?( Gem::ConfigMap[:bindir])
  sh "#{sudo} gem install #{spec.name}-#{spec.version}.gem"
end


task :default=>:test
desc "Run all tests using Redis mock (also default task)"
Rake::TestTask.new do |task|
  task.test_files = FileList['test/unit/test_*.rb']
  if Rake.application.options.trace
    #task.warning = true
    task.verbose = true
  elsif Rake.application.options.silent
    task.ruby_opts << "-W0"
  else
    task.verbose = true
  end
end


begin
  require "yard"
  YARD::Rake::YardocTask.new(:yardoc) do |task|
    task.files  = FileList["lib/**/*.rb"]
    task.options = "--output", "html", "--title", "Pipemaster #{spec.version}", "--main", "README.rdoc", "--files", "CHANGELOG"
  end
rescue LoadError
end

desc "Create documentation in html directory"
task :docs=>[:yardoc]
desc "Remove temporary files and directories"
task(:clobber) { rm_rf "html" }
