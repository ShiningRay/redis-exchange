# frozen_string_literal: true

require_relative 'lib/redis_exchange/version'

Gem::Specification.new do |spec|
  spec.name          = 'redis_exchange'
  spec.version       = RedisExchange::VERSION
  spec.authors       = ['Shiningray']
  spec.email         = ['example@example.com']

  spec.summary       = 'Redis-backed matching engine and ticker powered by Lua'
  spec.description   = 'A reference central limit order book implemented with Redis data structures, a Lua matching script, and built-in market ticker snapshots.'
  spec.homepage      = 'https://github.com/ShiningRay/redis-exchange'
  spec.license       = 'MIT'
  spec.metadata["github_repo"] = "https://github.com/ShiningRay/redis-exchange"
  spec.metadata["allowed_push_host"] = "https://rubygems.pkg.github.com/ShiningRay"
  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['lib/**/*.rb'] + Dir['redis_scripts/*.lua'] + [
      'README.md',
      'docs/architecture.md',
      'script/maintenance/adjust_precision.rb',
      'script/export_snapshot.rb',
      'script/export_rdb_data.sh'
    ]
  end
  spec.bindir        = 'exe'
  spec.executables   = []
  spec.require_paths = ['lib']

  spec.add_dependency 'redis', '>= 5.0'
  spec.add_dependency 'csv', '>= 3.0'
  spec.add_dependency 'bigdecimal'

  spec.add_development_dependency 'rspec', '>= 3.12'
  spec.add_development_dependency 'hiredis', '>= 0.6'
  spec.add_development_dependency 'rake', '>= 13.0'
end
