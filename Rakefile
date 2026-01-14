require "bundler/gem_tasks"
require "rspec/core/rake_task"

# Load custom tasks
Dir.glob('lib/tasks/*.rake').each { |r| import r }

RSpec::Core::RakeTask.new(:spec)

task default: :spec
