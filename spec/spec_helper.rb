# frozen_string_literal: true

require 'rspec'

module SpecRedis
  class << self
    def factory
      url = ENV['SPEC_REDIS_URL'] || ENV['REDIS_URL']
      return fallback_factory unless url && !url.empty?

      begin
        require 'redis'
      rescue LoadError
        return fallback_factory
      end

      lambda do
        client = ::Redis.new(url: url)
        begin
          client.ping
          client
        rescue StandardError
          client.close if client.respond_to?(:close)
          fallback_factory.call
        end
      end
    end

    private

    def fallback_factory
      require 'redis_exchange/in_memory_redis'
      lambda { RedisExchange::InMemoryRedis.new }
    end
  end
end

RSpec.configure do |config|
  config.add_setting :redis_factory, default: SpecRedis.factory
end

require 'redis_exchange'

RSpec.configure do |config|
  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

end
