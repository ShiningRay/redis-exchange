# frozen_string_literal: true

module RedisExchange
  class Maintenance
    MAINTENANCE_KEY = 'system:maintenance_mode'

    def initialize(redis)
      @redis = redis
    end

    def enable
      @redis.set(MAINTENANCE_KEY, '1')
    end

    def disable
      @redis.del(MAINTENANCE_KEY)
    end

    def enabled?
      @redis.get(MAINTENANCE_KEY) == '1'
    end

    def enable_market(symbol)
      @redis.hset("market:#{symbol}", 'maintenance', '1')
    end

    def disable_market(symbol)
      @redis.hdel("market:#{symbol}", 'maintenance')
    end

    def market_enabled?(symbol)
      @redis.hget("market:#{symbol}", 'maintenance') == '1'
    end

    # Atomically snapshot order book for a symbol.
    # Uses market-level maintenance mode to ensure consistency without blocking Redis.
    # @param symbol [String] market symbol
    # @param output_path [String,nil] if provided, streams JSON output to this file; otherwise returns Hash
    # @return [Hash,String] returns Hash if output_path is nil; otherwise returns output_path
    def snapshot_order_book(symbol:, output_path: nil)
      enable_market(symbol)
      output = output_path ? File.open(output_path, 'w') : nil
      
      begin
        result_hash = output ? nil : { symbol: symbol, bids: [], asks: [] }
        
        if output
          output.write("{\"symbol\":\"#{symbol}\",\"timestamp\":#{Time.now.to_i},\"bids\":[")
        end
        
        # Stream Bids
        stream_book_side(symbol, 'BUY', output, result_hash ? result_hash[:bids] : nil)
        
        if output
          output.write("],\"asks\":[")
        end
        
        # Stream Asks
        stream_book_side(symbol, 'SELL', output, result_hash ? result_hash[:asks] : nil)
        
        if output
          output.write("]}")
          output.close
          output_path
        else
          result_hash
        end
      ensure
        if output && !output.closed?
          output.close
        end
        disable_market(symbol)
      end
    end

    # Atomically snapshot all user balances.
    # Uses system maintenance mode to ensure consistency without blocking Redis.
    # @param output_path [String,nil] if provided, streams JSON output to this file; otherwise returns Hash
    # @return [Hash,String] returns Hash if output_path is nil; otherwise returns output_path
    def snapshot_balances(output_path: nil)
      enable
      output = output_path ? File.open(output_path, 'w') : {}
      
      begin
        if output.is_a?(File)
          output.write('{')
        end
        
        first_entry = true
        cursor = '0'
        loop do
          cursor, keys = @redis.scan(cursor, match: 'balance:*', count: 1000)
          
          if keys.any?
            # Pipeline HGETALL for this batch
            responses = @redis.pipelined do |pipeline|
              keys.each { |k| pipeline.hgetall(k) }
            end
            
            keys.each_with_index do |key, idx|
              user_id = key.sub('balance:', '')
              fields = responses[idx]
              
              user_balance = {}
              fields.each do |field, value|
                 # Field format: "ASSET:available" or "ASSET:reserved"
                 parts = field.split(':')
                 if parts.length == 2
                   asset = parts[0]
                   type = parts[1]
                   if type == 'available' || type == 'reserved'
                     user_balance[asset] ||= { 'available' => 0, 'reserved' => 0 }
                     user_balance[asset][type] = value.to_i
                   end
                 end
              end
              
              unless user_balance.empty?
                if output.is_a?(File)
                  output.write(',') unless first_entry
                  output.write("#{JSON.generate(user_id)}:#{JSON.generate(user_balance)}")
                  first_entry = false
                else
                  output[user_id] = user_balance
                end
              end
            end
          end
          
          break if cursor == '0'
        end
        
        if output.is_a?(File)
          output.write('}')
          output.close
          output_path
        else
          output
        end
      ensure
        if output.is_a?(File) && !output.closed?
          output.close
        end
        disable
      end
    end

    private

    def stream_book_side(symbol, side, file_output, array_output)
      book_key = "book:#{symbol}:#{side}"
      volume_key = "volume:#{symbol}:#{side}"
      
      cursor = '0'
      first_entry = true
      
      loop do
        cursor, prices_with_scores = @redis.zscan(book_key, cursor, count: 1000)
        
        if prices_with_scores.any?
          prices = prices_with_scores.map(&:first)
          volumes = @redis.hmget(volume_key, *prices)
          
          prices.each_with_index do |price, idx|
            entry = { price: price.to_i, volume: volumes[idx].to_i }
            
            if file_output
              file_output.write(',') unless first_entry
              file_output.write(JSON.generate(entry))
              first_entry = false
            else
              array_output << entry
            end
          end
        end
        
        break if cursor == '0'
      end
    end
  end
end
