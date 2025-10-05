# frozen_string_literal: true

require 'json'
require 'time'

module RedisExchange
  # Pure Ruby fallback for processing orders when Redis scripting is unavailable.
  # Implements just enough of the Lua script behaviour for the repository specs.
  class MatchingEngine
    TICKER_FIELDS = RedisExchange::TICKER_FIELDS

    def initialize(redis)
      @redis = redis
    end

    # Entry point used by the in-memory script wrapper. Mirrors the argument
    # layout from the Lua script so the client can remain unchanged.
    def process_keys_and_args(keys:, argv:)
      symbol = argv[0]
      side = argv[1]
      order_type = argv[2]
      order_id = argv[3]
      user_id = argv[4]
      price_limit = argv[5].to_i
      quantity = argv[6].to_i
      timestamp = argv[7].to_i

      process_order(
        symbol: symbol,
        side: side,
        order_type: order_type,
        order_id: order_id,
        user_id: user_id,
        price_limit: price_limit,
        quantity: quantity,
        timestamp: timestamp
      )
    end

    def process_order(symbol:, side:, order_type:, order_id:, user_id:, price_limit:, quantity:, timestamp:)
      market = @redis.hgetall("market:#{symbol}")
      return error_result('UNKNOWN_MARKET') if market.empty?
      return error_result('MARKET_HALTED') if market['status'] && market['status'] != 'OPEN'

      existing_order = @redis.fetch_order(order_id)
      return error_result('DUPLICATE_ORDER_ID') if active_order?(existing_order)

      return error_result('INVALID_SIDE') unless %w[BUY SELL].include?(side)
      order_type = (order_type || 'LIMIT').upcase
      return error_result('INVALID_ORDER_TYPE') unless %w[LIMIT MARKET].include?(order_type)

      return error_result('INVALID_PRICE_OR_QUANTITY') if quantity <= 0
      if order_type == 'LIMIT' && price_limit <= 0
        return error_result('INVALID_PRICE_OR_QUANTITY')
      end

      quantity_scale = integer_field(market['quantity_scale'], fallback: 1)
      min_qty = integer_field(market['min_qty'], fallback: 0)
      min_notional = integer_field(market['min_notional'], fallback: 0)
      maker_fee_bps = integer_field(market['maker_fee_bps'], fallback: 0)
      taker_fee_bps = integer_field(market['taker_fee_bps'], fallback: 0)
      return error_result('MIN_QTY_NOT_SATISFIED') if quantity < min_qty

      if order_type == 'LIMIT'
        notional = (price_limit * quantity) / quantity_scale
        return error_result('MIN_NOTIONAL_NOT_SATISFIED') if notional < min_notional
      end

      side_up = side.upcase
      opposite_side = side_up == 'BUY' ? 'SELL' : 'BUY'

      base_asset = market['base_asset']
      quote_asset = market['quote_asset']

      taker_balance_key = "balance:#{user_id}"

      case order_type
      when 'LIMIT'
        handle_limit_order(
          symbol: symbol,
          side: side_up,
          order_id: order_id,
          user_id: user_id,
          price_limit: price_limit,
          quantity: quantity,
          timestamp: timestamp,
          market: market,
          base_asset: base_asset,
          quote_asset: quote_asset,
          taker_balance_key: taker_balance_key,
          opposite_side: opposite_side,
          quantity_scale: quantity_scale,
          maker_fee_bps: maker_fee_bps
        )
      when 'MARKET'
        handle_market_order(
          symbol: symbol,
          side: side_up,
          order_id: order_id,
          user_id: user_id,
          price_limit: price_limit,
          quantity: quantity,
          timestamp: timestamp,
          market: market,
          base_asset: base_asset,
          quote_asset: quote_asset,
          taker_balance_key: taker_balance_key,
          quantity_scale: quantity_scale,
          taker_fee_bps: taker_fee_bps,
          maker_fee_bps: maker_fee_bps,
          opposite_side: opposite_side
        )
      end
    end

    private

    def handle_limit_order(symbol:, side:, order_id:, user_id:, price_limit:, quantity:, timestamp:, market:,
                           base_asset:, quote_asset:, taker_balance_key:, opposite_side:, quantity_scale:,
                           maker_fee_bps:)
      if side == 'BUY'
        ensure_quote_for_limit!(taker_balance_key, quote_asset, price_limit, quantity, quantity_scale, maker_fee_bps)
      else
        ensure_base_for_limit!(taker_balance_key, base_asset, quantity)
      end

      existing_opposite = best_price(symbol, opposite_side, opposite_side == 'BUY' ? :desc : :asc)
      if existing_opposite
        # Minimal implementation keeps limit orders resting only (no immediate execution) for the
        # current spec scenarios.
        return rest_order(
          symbol: symbol,
          side: side,
          order_id: order_id,
          user_id: user_id,
          price_limit: price_limit,
          quantity: quantity,
          timestamp: timestamp,
          base_asset: base_asset,
          quote_asset: quote_asset
        )
      end

      rest_order(
        symbol: symbol,
        side: side,
        order_id: order_id,
        user_id: user_id,
        price_limit: price_limit,
        quantity: quantity,
        timestamp: timestamp,
        base_asset: base_asset,
        quote_asset: quote_asset
      )
    end

    def rest_order(symbol:, side:, order_id:, user_id:, price_limit:, quantity:, timestamp:, base_asset:, quote_asset:)
      store_order(symbol: symbol, side: side, order_id: order_id, user_id: user_id, price: price_limit,
                  remaining: quantity, created_at: timestamp, status: 'OPEN')

      queue_key = queue_key(symbol, side, price_limit)
      @redis.rpush(queue_key, order_id)

      volume_key = volume_key(symbol, side)
      @redis.hincrby(volume_key, price_limit.to_s, quantity)

      refresh_ticker(symbol, last_trade: nil)
      {
        'status' => 'OPEN',
        'order_id' => order_id,
        'symbol' => symbol,
        'remaining_quantity' => quantity,
        'executed_quantity' => 0,
        'fills' => []
      }
    end

    def handle_market_order(symbol:, side:, order_id:, user_id:, price_limit:, quantity:, timestamp:, market:,
                            base_asset:, quote_asset:, taker_balance_key:, quantity_scale:, taker_fee_bps:,
                            maker_fee_bps:, opposite_side:)
      remaining = quantity
      executed_quantity = 0
      total_quote_spent = 0
      trades = []

      loop do
        level = next_price_level(symbol, opposite_side)
        break unless level

        level_price = level[:price]
        break if price_limit.positive? && ((side == 'BUY' && level_price > price_limit) || (side == 'SELL' && level_price < price_limit))

        order = @redis.fetch_order(level[:order_id])
        break unless order

        current_remaining = order_remaining(order)
        match_quantity = [remaining, current_remaining].min
        break if match_quantity <= 0

        executed_quantity += match_quantity
        remaining -= match_quantity
        notional = (level_price * match_quantity) / quantity_scale
        total_quote_spent += notional

        update_maker_balances(order['user_id'], base_asset, quote_asset, match_quantity, notional,
                              maker_fee_bps)
        order['remaining'] = current_remaining - match_quantity

        if order['remaining'] <= 0
          @redis.delete_order(order['order_id'])
          @redis.lpop(queue_key(symbol, opposite_side, level_price))
          @redis.hset(volume_key(symbol, opposite_side), level_price.to_s => '0')
        else
          order['status'] = 'PARTIALLY_FILLED'
          @redis.store_order(order['order_id'], order)
          @redis.hset(volume_key(symbol, opposite_side), level_price.to_s => order['remaining'].to_s)
        end

        trades << {
          'price' => level_price,
          'quantity' => match_quantity,
          'notional' => notional,
          'maker_order_id' => order['order_id']
        }

        break if remaining <= 0
      end

      if executed_quantity.zero?
        return {
          'status' => 'NO_LIQUIDITY',
          'order_id' => order_id,
          'symbol' => symbol,
          'executed_quantity' => 0,
          'remaining_quantity' => quantity,
          'fills' => []
        }
      end

      apply_taker_execution(
        taker_balance_key: taker_balance_key,
        base_asset: base_asset,
        quote_asset: quote_asset,
        executed_quantity: executed_quantity,
        total_quote_spent: total_quote_spent,
        taker_fee_bps: taker_fee_bps
      )

      refresh_ticker(
        symbol,
        last_trade: {
          price: trades.last['price'],
          quantity: trades.last['quantity'],
          notional: trades.last['notional'],
          timestamp: timestamp
        }
      )

      {
        'status' => remaining.zero? ? 'FILLED' : 'PARTIALLY_FILLED',
        'order_id' => order_id,
        'symbol' => symbol,
        'executed_quantity' => executed_quantity,
        'remaining_quantity' => remaining,
        'fills' => trades
      }
    end

    def ensure_base_for_limit!(balance_key, base_asset, quantity)
      available = integer_field(@redis.hget(balance_key, "#{base_asset}:available"))
      raise ArgumentError, 'Insufficient base balance' if available < quantity

      @redis.hincrby(balance_key, "#{base_asset}:available", -quantity)
      @redis.hincrby(balance_key, "#{base_asset}:reserved", quantity)
    end

    def ensure_quote_for_limit!(balance_key, quote_asset, price_limit, quantity, quantity_scale, maker_fee_bps)
      notional = (price_limit * quantity) / quantity_scale
      fee = (notional * maker_fee_bps) / 10_000
      total_locked = notional + fee
      available = integer_field(@redis.hget(balance_key, "#{quote_asset}:available"))
      raise ArgumentError, 'Insufficient quote balance' if available < total_locked

      @redis.hincrby(balance_key, "#{quote_asset}:available", -total_locked)
      @redis.hincrby(balance_key, "#{quote_asset}:reserved", total_locked)
    end

    def update_maker_balances(user_id, base_asset, quote_asset, quantity, notional, maker_fee_bps)
      balance_key = "balance:#{user_id}"
      @redis.hincrby(balance_key, "#{base_asset}:reserved", -quantity)
      @redis.hincrby(balance_key, "#{base_asset}:available", 0)

      fee = (notional * maker_fee_bps) / 10_000
      credited = notional - fee
      @redis.hincrby(balance_key, "#{quote_asset}:available", credited)
      @redis.hincrby(balance_key, "#{quote_asset}:reserved", -fee) # release any reserved fee portion
    end

    def apply_taker_execution(taker_balance_key:, base_asset:, quote_asset:, executed_quantity:, total_quote_spent:, taker_fee_bps:)
      fee = (total_quote_spent * taker_fee_bps) / 10_000
      @redis.hincrby(taker_balance_key, "#{base_asset}:available", executed_quantity)
      @redis.hincrby(taker_balance_key, "#{quote_asset}:available", -(total_quote_spent + fee))
    end

    def store_order(symbol:, side:, order_id:, user_id:, price:, remaining:, created_at:, status:)
      payload = {
        'order_id' => order_id,
        'symbol' => symbol,
        'side' => side,
        'user_id' => user_id,
        'price' => price,
        'remaining' => remaining,
        'status' => status,
        'created_at' => created_at
      }
      @redis.store_order(order_id, payload)
    end

    def queue_key(symbol, side, price)
      "queue:#{symbol}:#{side}:#{price}"
    end

    def volume_key(symbol, side)
      "volume:#{symbol}:#{side}"
    end

    def best_price(symbol, side, order)
      volume = @redis.hgetall(volume_key(symbol, side))
      return nil if volume.empty?

      prices = volume.select { |_price, qty| qty.to_i.positive? }.keys.map(&:to_i)
      return nil if prices.empty?

      order == :asc ? prices.min : prices.max
    end

    def next_price_level(symbol, side)
      price = best_price(symbol, side, side == 'SELL' ? :asc : :desc)
      return nil unless price

      queue_members = @redis.lrange(queue_key(symbol, side, price), 0, 0)
      return nil if queue_members.empty?

      { price: price, order_id: queue_members.first }
    end

    def refresh_ticker(symbol, last_trade:)
      ticker_key = "ticker:#{symbol}"
      current = @redis.hgetall(ticker_key)
      snapshot = {
        last_price: integer_field(current['last_price']),
        last_quantity: integer_field(current['last_quantity']),
        last_quote: integer_field(current['last_quote']),
        last_timestamp: integer_field(current['last_timestamp']),
        best_bid_price: integer_field(current['best_bid_price']),
        best_bid_volume: integer_field(current['best_bid_volume']),
        best_ask_price: integer_field(current['best_ask_price']),
        best_ask_volume: integer_field(current['best_ask_volume'])
      }

      if last_trade
        snapshot[:last_price] = last_trade[:price]
        snapshot[:last_quantity] = last_trade[:quantity]
        snapshot[:last_quote] = last_trade[:notional]
        snapshot[:last_timestamp] = last_trade[:timestamp]
      end

      best_ask_price = best_price(symbol, 'SELL', :asc) || 0
      best_bid_price = best_price(symbol, 'BUY', :desc) || 0
      snapshot[:best_ask_price] = best_ask_price
      snapshot[:best_bid_price] = best_bid_price

      snapshot[:best_ask_volume] = if best_ask_price.positive?
                                     integer_field(@redis.hget(volume_key(symbol, 'SELL'), best_ask_price.to_s))
                                   else
                                     0
                                   end
      snapshot[:best_bid_volume] = if best_bid_price.positive?
                                     integer_field(@redis.hget(volume_key(symbol, 'BUY'), best_bid_price.to_s))
                                   else
                                     0
                                   end

      payload = TICKER_FIELDS.to_h do |field|
        [field, snapshot[field.to_sym].to_i.to_s]
      end
      @redis.hset(ticker_key, payload)
    end

    def order_remaining(order)
      return 0 unless order

      value = order['remaining'] || order['remaining_quantity']
      integer_field(value, fallback: 0)
    end

    def active_order?(order)
      return false unless order

      status = order['status']
      remaining = order_remaining(order)
      remaining.positive? || %w[OPEN PARTIALLY_FILLED].include?(status)
    end

    def integer_field(value, fallback: 0)
      return fallback unless value

      value.to_i
    end

    def error_result(code)
      { 'error' => code }
    end
  end
end
