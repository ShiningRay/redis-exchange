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
## No Ruby fallback or in-memory shim; all logic uses real Redis + Lua

module RedisExchange
  # Client encapsulates Lua script execution and convenience helpers.
  class Client

    # @param redis [Redis] configured Redis connection
    # @param script_path [String,nil] optional override for the Lua script path
    def initialize(redis:, script_path: nil)
      @redis = redis

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
    # @param symbol [String] market symbol (e.g., 'BTCUSDT')
    # @param base_asset [String] base asset code (e.g., 'BTC')
    # @param quote_asset [String] quote asset code (e.g., 'USDT')
    # @param price_scale [Integer] price precision scale (price in quote minor units)
    # @param quantity_scale [Integer] quantity precision scale (quantity in base minor units)
    # @param maker_fee_bps [Integer] maker fee in basis points (0..10000)
    # @param taker_fee_bps [Integer] taker fee in basis points (0..10000)
    # @param min_qty [Integer] minimum order quantity in base minor units
    # @param min_notional [Integer] minimum notional in quote minor units
    # @param trades_maxlen [Integer,nil] max trades stream length; nil uses default (1_000_000)
    # @param orders_maxlen [Integer,nil] max orders stream length; nil uses default (1_000_000)
    def seed_market(symbol:, base_asset:, quote_asset:, price_scale: 1, quantity_scale: 1,
                  maker_fee_bps: 0, taker_fee_bps: 0, min_qty: 1, min_notional: 1,
                  trades_maxlen: nil, orders_maxlen: nil)
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
      mapping['trades_maxlen'] = trades_maxlen.to_i if trades_maxlen
      mapping['orders_maxlen'] = orders_maxlen.to_i if orders_maxlen
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

    # Retrieve an order snapshot by id with typed fields.
    # @param order_id [String]
    # @return [Hash] empty hash when not found; otherwise typed fields
    #   Keys:
    #   - :order_id, :user_id, :symbol, :side, :type, :status (String)
    #   - :price, :quantity, :remaining, :created_at, :sequence (Integer)
    def order(order_id)
      raw = @redis.hgetall("order:#{order_id}")
      return {} if raw.empty?

      {
        order_id: raw.fetch('order_id', order_id),
        user_id: raw['user_id'],
        symbol: raw['symbol'],
        side: raw['side'],
        type: raw['type'],
        status: raw['status'],
        price: raw.fetch('price', '0').to_i,
        quantity: raw.fetch('quantity', '0').to_i,
        remaining: raw.fetch('remaining', '0').to_i,
        created_at: raw.fetch('created_at', '0').to_i,
        sequence: raw.fetch('sequence', '0').to_i
      }
    end

    # Cancel a resting order and release any reserved balances.
    # Returns a status hash mirroring Lua responses.
    def cancel_order(order_id)
      payload = { keys: ["order:#{order_id}"], argv: [order_id] }
      raw = call_script(@cancel_script, payload)
      JSON.parse(raw)
    end

    def cancel_all_orders(user_id)
      payload = { keys: [], argv: [user_id] }
      raw = call_script(@cancel_all_script, payload)
      JSON.parse(raw)
    end

    # 分页查询用户在某交易对的活跃订单（OPEN/PARTIALLY_FILLED 且 remaining>0）。
    # 依赖 Lua 维护的 ZSET 索引：`user_orders:{user_id}:{symbol}`，score 使用撮合序列。
    # @param user_id [String]
    # @param symbol [String]
    # @param page [Integer] 从 1 开始的页码
    # @param per_page [Integer] 每页条数，默认 50
    # @param direction [Symbol] :asc 或 :desc（根据序列顺序）
    # @return [Array<Hash>] 订单快照数组
    def active_orders(user_id:, symbol:, page: 1, per_page: 50, direction: :desc)
      page = page.to_i
      per_page = per_page.to_i
      page = 1 if page <= 0
      per_page = 50 if per_page <= 0

      index_key = "user_orders:#{user_id}:#{symbol}"
      start = (page - 1) * per_page
      stop = start + per_page - 1

      range_method = direction.to_sym == :asc ? :zrange : :zrevrange
      ids = Array(@redis.public_send(range_method, index_key, start, stop))
      return [] if ids.empty?

      ids.map { |id| order(id) }.select { |o| !o.empty? && o[:remaining].positive? && (o[:status] == 'OPEN' || o[:status] == 'PARTIALLY_FILLED') }
    end

    # Build a TradeStreamConsumer for a market symbol.
    # Usage: consumer = exchange.trade_consumer(symbol: 'BTCUSDT', group: 'trades-consumers', consumer: 'worker-1')
    def trade_consumer(symbol:, group:, consumer:)
      require_relative 'redis_exchange/trade_stream_consumer'
      c = RedisExchange::TradeStreamConsumer.new(redis: @redis, symbol: symbol, group: group, consumer: consumer)
      c.ensure_group(start_id: '0')
      c
    end

    # Build an OrderStreamConsumer for a market symbol.
    # Usage: consumer = exchange.order_consumer(symbol: 'BTCUSDT', group: 'orders-consumers', consumer: 'worker-1')
    def order_consumer(symbol:, group:, consumer:)
      require_relative 'redis_exchange/order_stream_consumer'
      c = RedisExchange::OrderStreamConsumer.new(redis: @redis, symbol: symbol, group: group, consumer: consumer)
      c.ensure_group(start_id: '0')
      c
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

      # Precision pre-check (Ruby layer): both price_limit and quantity are scaled integers.
      # Prevent sending arguments that would overflow Lua's double precision (~9e15).
      precision_bound = 9_000_000_000_000_000
      pl = price_limit.to_i
      qty = quantity.to_i
      if pl.negative? || qty <= 0
        return { 'error' => 'INVALID_PRICE_OR_QUANTITY' }
      end
      if pl > 0
        # If either operand or the product breaches the bound, abort.
        # allow product equal to bound; overflow only when strictly greater
        if pl >= precision_bound || qty >= precision_bound || (pl.to_i * qty.to_i) > precision_bound
          return { 'error' => 'PRECISION_OVERFLOW' }
        end
      end

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
          keys[:trades],
          keys[:orders]
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
        trades: "trades:#{symbol}",
        orders: "orders:#{symbol}"
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

    # Simple Lua script wrapper using SCRIPT LOAD + EVALSHA.
    class LuaScript
      def initialize(source)
        @source = source
        @sha = nil
      end

      def call(redis, keys:, argv:)
        @sha ||= redis.script(:load, @source)
        redis.evalsha(@sha, keys: keys, argv: argv)
      rescue ::Redis::CommandError => e
        if e.message =~ /NOSCRIPT/
          @sha = redis.script(:load, @source)
          retry
        else
          raise
        end
      end
    end

    def register_script(lua_source)
      raise ArgumentError, 'missing Lua source' unless lua_source && !lua_source.empty?
      LuaScript.new(lua_source)
    end

    def execute_via_match_script(script_payload)
      call_script(@match_script, script_payload)
    end

    def read_script(path)
      return nil unless path && File.exist?(path)

      File.read(path)
    end

    def call_script(script, payload)
      script.call(@redis, **payload)
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
      stop = limit ? limit - 1 : -1
      raw = @redis.public_send(range_method, book_key, 0, stop, with_scores: true)
      pairs = if raw.is_a?(Array) && raw.first.is_a?(Array)
        raw
      else
        Array(raw).each_slice(2).to_a
      end
      list = pairs.map do |member, score|
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
    

    # Fallback-related helpers removed; cancellations handled via Lua scripts.
  end
end
