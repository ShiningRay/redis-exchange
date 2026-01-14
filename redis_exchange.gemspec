# frozen_string_literal: true

require_relative 'lib/redis_exchange/version'

Gem::Specification.new do |spec|
  spec.name          = 'redis_exchange'
  spec.version       = RedisExchange::VERSION
  spec.authors       = ['Shiningray']
  spec.email         = ['example@example.com']

  spec.summary       = 'Redis-backed matching engine and ticker powered by Lua'
  spec.description   = 'A reference central limit order book implemented with Redis data structures, a Lua matching script, and built-in market ticker snapshots.'
  spec.homepage      = 'https://example.com/redis_exchange'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.0'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['lib/**/*.rb'] + [
      'redis_scripts/match_order.lua',
      'redis_scripts/cancel_order.lua',
      'redis_scripts/cancel_all_orders.lua',
      'README.md',
      'docs/architecture.md'
    ]
  end
  spec.bindir        = 'exe'
  spec.executables   = []
  spec.require_paths = ['lib']

  spec.add_dependency 'redis', '>= 5.0'

  spec.add_development_dependency 'rspec', '>= 3.12'
  spec.add_development_dependency 'hiredis', '>= 0.6'
  spec.add_development_dependency 'rake', '>= 13.0'
end
