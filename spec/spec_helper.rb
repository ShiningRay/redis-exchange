# frozen_string_literal: true

require 'rspec'

module SpecRedis
  class << self
    def factory
      url = ENV['SPEC_REDIS_URL'] || ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/15'
      require 'redis'
      # Prefer hiredis driver if gem is available
      driver = begin
        require 'hiredis'
        :hiredis
      rescue LoadError
        nil
      end
      lambda do
        opts = { url: url }
        client = nil
        if driver
          begin
            client = ::Redis.new(**opts.merge(driver: :hiredis))
          rescue ArgumentError
            client = ::Redis.new(**opts)
          end
        else
          client = ::Redis.new(**opts)
        end
        client.ping # raises if unavailable
        client
      end
    end
  end
end

RSpec.configure do |config|
  config.add_setting :redis_factory, default: SpecRedis.factory
end

require 'redis_exchange'

# Load support files (shared contexts, helpers)
Dir[File.expand_path('support/**/*.rb', __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

end
