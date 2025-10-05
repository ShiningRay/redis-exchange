# frozen_string_literal: true

# RedisExchange::Client
# ----------------------
# High-level Ruby façade for the Redis/Lua matching engine.
#
# Responsibilities:
# - Load and register the `match_order.lua` script against a provided Redis
#   connection.
# - Expose convenience helpers to seed market metadata, manage balances,
#   submit limit and market orders, and clear a market during tests.
# - Surfaces `ticker(symbol)` which reads the `ticker:{symbol}` hash maintained
#   by the Lua script (last trade + best bid/ask snapshot).
#
# Numeric conventions:
# - All amounts are integer minor units; scales are defined in `seed_market`.
# - Keep values < 9e15 to stay within Lua double precision.

require 'json'
require 'redis' unless defined?(Redis)
require 'time'

module RedisExchange
  TICKER_FIELDS = %w[
    last_price
    last_quantity
    last_quote
    last_timestamp
    best_bid_price
    best_bid_volume
    best_ask_price
    best_ask_volume
  ].freeze
end

require_relative 'redis_exchange/version'
require_relative 'redis_exchange/matching_engine'
require_relative 'redis_exchange/in_memory_redis'

module RedisExchange
  # Client encapsulates Lua script execution and convenience helpers.
  class Client

    # @param redis [Redis] configured Redis connection
    # @param script_path [String,nil] optional override for the Lua script path
    def initialize(redis:, script_path: nil)
      @redis = redis
      @engine = MatchingEngine.new(@redis)

      path = script_path || default_script_path
      @lua_source = File.exist?(path) ? File.read(path) : nil
      @script = register_script(@lua_source)
    end

    # Submit a limit order and return the Redis/Lua response hash.
    # @param symbol [String] market symbol
    # @param side [String, Symbol] 'BUY' or 'SELL'
    # @param order_id [String] unique order identifier
    # @param user_id [String] owner of the order
    # @param price [Integer] scaled limit price
    # @param quantity [Integer] scaled quantity
    # @param timestamp_ms [Integer,nil] optional epoch in milliseconds
    # @return [Hash] parsed Lua response
    def place_limit_order(symbol:, side:, order_id:, user_id:, price:, quantity:, timestamp_ms: nil)
      raise ArgumentError, 'price must be positive for limit orders' unless price.positive?

      execute_order(
        symbol: symbol,
        side: side,
        order_type: 'LIMIT',
        order_id: order_id,
        user_id: user_id,
        price_limit: price,
        quantity: quantity,
        timestamp_ms: timestamp_ms
      )
    end

    # Submit a market order; optional price_cap acts as a worst-case limit.
    # @param price_cap [Integer] 0 for uncapped markets
    # Other params mirror #place_limit_order
    def place_market_order(symbol:, side:, order_id:, user_id:, quantity:, price_cap: 0, timestamp_ms: nil)
      raise ArgumentError, 'price_cap must be non-negative' if price_cap.negative?

      execute_order(
        symbol: symbol,
        side: side,
        order_type: 'MARKET',
        order_id: order_id,
        user_id: user_id,
        price_limit: price_cap,
        quantity: quantity,
        timestamp_ms: timestamp_ms
      )
    end

    # Return the ticker hash for a market with integer values.
    # @param symbol [String] market symbol
    # @return [Hash{Symbol=>Integer}] last trade + top-of-book snapshot
    def ticker(symbol)
      raw = @redis.hgetall("ticker:#{symbol}")
      return {} if raw.empty?

      RedisExchange::TICKER_FIELDS.to_h do |field|
        [field.to_sym, raw.fetch(field, '0').to_i]
      end
    end

    # Seed or update market metadata.
    # @param price_scale [Integer] price precision scale
    # @param quantity_scale [Integer] quantity precision scale
    def seed_market(symbol:, base_asset:, quote_asset:, price_scale: 1, quantity_scale: 1,
                    maker_fee_bps: 0, taker_fee_bps: 0, min_qty: 1, min_notional: 1)
      key = "market:#{symbol}"
      mapping = {
        'base_asset' => base_asset,
        'quote_asset' => quote_asset,
        'price_scale' => price_scale,
        'quantity_scale' => quantity_scale,
        'maker_fee_bps' => maker_fee_bps,
        'taker_fee_bps' => taker_fee_bps,
        'min_qty' => min_qty,
        'min_notional' => min_notional,
        'status' => 'OPEN'
      }
      @redis.hset(key, mapping)
    end

    # Overwrite a user's available/reserved buckets for an asset.
    def set_balance(user_id:, asset:, available: 0, reserved: 0)
      key = "balance:#{user_id}"
      mapping = {
        "#{asset}:available" => available,
        "#{asset}:reserved" => reserved
      }
      @redis.hset(key, mapping)
    end

    # Remove book, volume, sequence, trades, and ticker keys for tests.
    def clear_books(symbol)
      keys = [
        "book:#{symbol}:BUY",
        "book:#{symbol}:SELL",
        "volume:#{symbol}:BUY",
        "volume:#{symbol}:SELL",
        "seq:#{symbol}",
        "trades:#{symbol}",
        "ticker:#{symbol}"
      ]
      @redis.del(*keys)
    end

    private

    # Internal helper to execute the Lua script with typed arguments.
    def execute_order(symbol:, side:, order_type:, order_id:, user_id:, price_limit:, quantity:, timestamp_ms: nil)
      side_up = side.to_s.upcase
      raise ArgumentError, 'side must be BUY or SELL' unless %w[BUY SELL].include?(side_up)

      type_up = order_type.to_s.upcase
      raise ArgumentError, 'order_type must be LIMIT or MARKET' unless %w[LIMIT MARKET].include?(type_up)

      ts = (timestamp_ms || current_millis).to_i
      keys = market_keys(symbol: symbol, user_id: user_id)
      script_payload = {
        keys: [
          keys[:market],
          keys[:sequence],
          keys[:book_buy],
          keys[:book_sell],
          keys[:volume_buy],
          keys[:volume_sell],
          keys[:balance],
          keys[:trades]
        ],
        argv: [
          symbol,
          side_up,
          type_up,
          order_id,
          user_id,
          price_limit.to_s,
          quantity.to_s,
          ts.to_s
        ]
      }

      raw = if @script
              @script.call(**script_payload)
            else
              JSON.generate(@engine.process_keys_and_args(**script_payload))
            end
      JSON.parse(raw)
    end

    # Build all Redis keys touched by the Lua script for a market/user pair.
    def market_keys(symbol:, user_id:)
      {
        market: "market:#{symbol}",
        sequence: "seq:#{symbol}",
        book_buy: "book:#{symbol}:BUY",
        book_sell: "book:#{symbol}:SELL",
        volume_buy: "volume:#{symbol}:BUY",
        volume_sell: "volume:#{symbol}:SELL",
        balance: "balance:#{user_id}",
        trades: "trades:#{symbol}"
      }
    end

    # Path to the bundled Lua matching script.
    def default_script_path
      File.expand_path('../redis_scripts/match_order.lua', __dir__)
    end

    # Current epoch time in milliseconds.
    def current_millis
      (Time.now.to_f * 1000).floor
    end

    def register_script(lua_source)
      return nil unless lua_source
      return nil unless @redis.respond_to?(:register_script)

      @redis.register_script(lua_source)
    rescue StandardError
      nil
    end
  end
end
