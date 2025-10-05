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

      match_script_path = script_path || default_script_path
      @match_script = register_script(read_script(match_script_path))

      cancel_path = File.expand_path('../redis_scripts/cancel_order.lua', __dir__)
      @cancel_script = register_script(read_script(cancel_path))

      cancel_all_path = File.expand_path('../redis_scripts/cancel_all_orders.lua', __dir__)
      @cancel_all_script = register_script(read_script(cancel_all_path))
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

    # Fetch all balance fields for a user as integers keyed by symbols.
    # @param user_id [String]
    # @return [Hash{Symbol=>Integer}]
    def balances(user_id)
      raw = @redis.hgetall("balance:#{user_id}")
      raw.each_with_object({}) do |(field, value), result|
        result[field.to_sym] = value.to_i
      end
    end

    # Cancel a resting order and release any reserved balances.
    # Returns a status hash mirroring Lua responses.
    def cancel_order(order_id)
      payload = { keys: ["order:#{order_id}"], argv: [order_id] }
      raw = call_script(@cancel_script, payload)
      return JSON.parse(raw) if raw

      cancel_order_fallback(order_id)
    end

    def cancel_all_orders(user_id)
      payload = { keys: [], argv: [user_id] }
      raw = call_script(@cancel_all_script, payload)
      return JSON.parse(raw) if raw

      cancel_all_orders_fallback(user_id)
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

    # Snapshot the current book depth for both sides.
    # @param limit [Integer,nil] maximum number of price levels per side
    # @return [Hash{Symbol=>Array<Hash{Symbol=>Integer}>}]
    def order_book(symbol, limit: nil)
      limit = limit&.to_i
      {
        bids: fetch_book_side(symbol, 'BUY', descending: true, limit: limit),
        asks: fetch_book_side(symbol, 'SELL', descending: false, limit: limit)
      }
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

      raw = execute_via_match_script(script_payload)
      raw ||= JSON.generate(@engine.process_keys_and_args(**script_payload))
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
      puts "Error registering script: #{$ERROR_INFO}"
      nil
    end

    def execute_via_match_script(script_payload)
      call_script(@match_script, script_payload)
    end

    def read_script(path)
      return nil unless path && File.exist?(path)

      File.read(path)
    end

    def call_script(script, payload)
      return nil unless script

      script.call(@redis, **payload)
    rescue StandardError
      nil
    end

    def cancel_order_fallback(order_id)
      order_key = "order:#{order_id}"
      order = @redis.hgetall(order_key)
      return { 'status' => 'NOT_FOUND', 'order_id' => order_id } if order.empty?

      remaining = order['remaining'].to_i
      status = order['status'] || 'UNKNOWN'
      return { 'status' => status, 'order_id' => order_id, 'symbol' => order['symbol'] } if remaining <= 0

      symbol = order['symbol']
      side = order['side']
      price = order['price'].to_i
      user_id = order['user_id']

      market = @redis.hgetall("market:#{symbol}")
      raise ArgumentError, 'unknown market' if market.empty?

      release_reserved_funds(market: market, side: side, user_id: user_id, price: price, remaining: remaining)
      remove_from_order_book(symbol: symbol, side: side, price: price, order_id: order_id, quantity: remaining)
      update_order_status(order_key, remaining: 0, status: 'CANCELLED')
      refresh_ticker_snapshot(symbol)

      {
        'status' => 'CANCELLED',
        'order_id' => order_id,
        'symbol' => symbol,
        'remaining_quantity' => 0
      }
    end

    def cancel_all_orders_fallback(user_id)
      results = []
      collect_order_keys.each do |order_key|
        next unless @redis.hget(order_key, 'user_id') == user_id
        status = @redis.hget(order_key, 'status')
        next if status && !%w[OPEN PARTIALLY_FILLED].include?(status)

        order_id = order_key.split(':', 2).last
        result = cancel_order_fallback(order_id)
        results << result if result['status'] == 'CANCELLED'
      end
      results
    end

    def collect_order_keys
      collect_keys('order:*')
    end

    def collect_queue_keys(symbol, side)
      collect_keys("queue:#{symbol}:#{side}:*")
    end

    def collect_keys(pattern)
      if @redis.respond_to?(:scan)
        cursor = '0'
        keys = []
        loop do
          scan_result = @redis.scan(cursor, match: pattern, count: 200)
          cursor = scan_result[0]
          keys.concat(Array(scan_result[1]))
          break if cursor == '0'
        end
        keys
      elsif @redis.respond_to?(:keys)
        Array(@redis.keys(pattern))
      else
        []
      end
    end

    def fetch_book_side(symbol, side, descending:, limit:)
      if supports_sorted_book?
        return fetch_sorted_book_side(symbol, side, descending: descending, limit: limit)
      end

      queue_keys = collect_queue_keys(symbol, side)
      entries = queue_keys.map do |key|
        price = key.split(':').last
        {
          price: price.to_i,
          volume: @redis.hget("volume:#{symbol}:#{side}", price).to_i
        }
      end
      entries.select! { |row| row[:volume].positive? }
      entries.sort_by! { |row| descending ? -row[:price] : row[:price] }
      limit ? entries.first(limit) : entries
    end

    def supports_sorted_book?
      @redis.respond_to?(:zrange) && @redis.respond_to?(:zrevrange)
    end

    def fetch_sorted_book_side(symbol, side, descending:, limit:)
      book_key = "book:#{symbol}:#{side}"
      volume_key = "volume:#{symbol}:#{side}"

      range_method = descending ? :zrevrange : :zrange
      args = [book_key, 0, limit ? limit - 1 : -1, { withscores: true }]
      raw = @redis.public_send(range_method, *args)
      list = Array(raw).each_slice(2).map do |member, score|
        price_str = member.to_s
        {
          price: price_str.to_i,
          volume: @redis.hget(volume_key, price_str).to_i,
          score: score.to_f
        }
      end
      list.select! { |row| row[:volume].positive? }
      limit ? list.first(limit) : list
    end
    def release_reserved_funds(market:, side:, user_id:, price:, remaining:)
      base_asset = market['base_asset']
      quote_asset = market['quote_asset']
      quantity_scale = [(market['quantity_scale'] || '1').to_i, 1].max
      maker_fee_bps = (market['maker_fee_bps'] || '0').to_i
      balance_key = "balance:#{user_id}"

      if side == 'SELL'
        @redis.hincrby(balance_key, "#{base_asset}:reserved", -remaining)
        @redis.hincrby(balance_key, "#{base_asset}:available", remaining)
      else
        notional = (price * remaining) / quantity_scale
        fee = (notional * maker_fee_bps) / 10_000
        total = notional + fee
        @redis.hincrby(balance_key, "#{quote_asset}:reserved", -total)
        @redis.hincrby(balance_key, "#{quote_asset}:available", total)
      end
    end

    def remove_from_order_book(symbol:, side:, price:, order_id:, quantity:)
      queue_key = "queue:#{symbol}:#{side}:#{price}"
      prune_queue(queue_key, order_id)

      volume_key = "volume:#{symbol}:#{side}"
      remaining_volume = @redis.hincrby(volume_key, price.to_s, -quantity)
      if remaining_volume <= 0
        @redis.hdel(volume_key, price.to_s) if @redis.respond_to?(:hdel)
        @redis.del(queue_key)

        book_key = side == 'BUY' ? "book:#{symbol}:BUY" : "book:#{symbol}:SELL"
        @redis.zrem(book_key, price.to_s) if @redis.respond_to?(:zrem)
      end
    end

    def prune_queue(queue_key, order_id)
      if @redis.respond_to?(:lrem)
        @redis.lrem(queue_key, 0, order_id)
      else
        entries = @redis.lrange(queue_key, 0, -1) || []
        filtered = entries.reject { |entry| entry == order_id }
        return if filtered == entries

        @redis.del(queue_key)
        filtered.each { |entry| @redis.rpush(queue_key, entry) }
      end
    end

    def update_order_status(order_key, remaining:, status:)
      fields = { 'remaining' => remaining.to_s, 'status' => status }
      if @redis.respond_to?(:hset)
        @redis.hset(order_key, fields)
      else
        current = @redis.hgetall(order_key)
        @redis.hset(order_key, current.merge(fields))
      end
    end

    def refresh_ticker_snapshot(symbol)
      @engine.send(:refresh_ticker, symbol, last_trade: nil)
    rescue StandardError
      nil
    end
  end
end
