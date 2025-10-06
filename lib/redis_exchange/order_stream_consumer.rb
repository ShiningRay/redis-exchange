# frozen_string_literal: true

require 'json'

module RedisExchange
  # OrderStreamConsumer
  # -------------------
  # 封装 `orders:{symbol}` 的 Redis Streams 消费者组操作：创建组、读取、ACK。
  # 与 TradeStreamConsumer 保持一致的 API 以便统一调用。
  class OrderStreamConsumer
    Entry = Struct.new(:stream, :id, :fields)

    attr_reader :redis, :symbol, :stream_key, :group, :consumer

    def initialize(redis:, symbol:, group:, consumer:)
      @redis = redis
      @symbol = symbol
      @stream_key = "orders:#{symbol}"
      @group = group
      @consumer = consumer
    end

    # 创建/确保消费者组存在；默认从 '0' 开始（包含历史 backlog）。
    def ensure_group(start_id: '0')
      begin
        @redis.xgroup(:create, stream_key, group, start_id, mkstream: true)
      rescue StandardError => e
        msg = e.message.to_s.downcase
        return if msg.include?('busygroup') || msg.include?('exists')
        raise
      end
      true
    end

    # 读取一批 entries，返回统一的 Entry 对象数组；无数据返回 []。
    def read(count: 100, block_ms: 2000)
      raw = @redis.xreadgroup(group, consumer, stream_key, '>', count: count, block: block_ms)
      normalize_read_result(raw)
    end

    # 便利循环：持续读取并将每条 entry 交给块处理。
    # 当块返回 :halt 时停止。auto_ack 为真时，块成功执行后自动 ACK。
    #
    # 示例：
    #   consumer.each(count: 100, block_ms: 2000, auto_ack: true) do |entry|
    #     persist(entry)
    #     # return :halt 停止循环
    #   end
    def each(count: 100, block_ms: 2000, auto_ack: false)
      raise ArgumentError, 'block required' unless block_given?
      loop do
        entries = read(count: count, block_ms: block_ms)
        next if entries.empty?

        entries.each do |e|
          begin
            result = yield e
            ack(e.id) if auto_ack
            return if result == :halt
          rescue StandardError => err
            warn "[#{self.class.name}] error processing #{stream_key} #{e.id}: #{err.message}"
            # 出错不 ACK；pending entries 将在后续重试/抢占
          end
        end
      end
    end

    # ACK 指定的 entry id。
    def ack(entry_id)
      @redis.xack(stream_key, group, entry_id)
    end

    # XPENDING 概览用于监控。
    def pending_summary
      @redis.xpending(stream_key, group)
    end

    # 抢占空闲的 pending entries（闲置超过 min_idle_ms）。
    # 返回被抢占的 entry ids。
    def claim_idle(min_idle_ms: 60_000, count: 10)
      summary = @redis.xpending(stream_key, group, '-', '+', count, consumer)
      ids = Array(summary).map { |row| row.is_a?(Array) ? row[0] : row['entry_id'] }.compact
      ids = ids.first(count)
      return [] if ids.empty?
      @redis.xclaim(stream_key, group, consumer, min_idle_ms, ids)
      ids
    end

    private

    # 统一标准化 Redis gem 的返回格式为 [Entry]。
    def normalize_read_result(raw)
      return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

      if raw.is_a?(Hash)
        entries = []
        list = raw[stream_key] || []
        list.each do |pair|
          id, fields = pair
          entries << Entry.new(stream_key, id, fields_to_hash(fields))
        end
        return entries
      end

      if raw.is_a?(Array)
        entries = []
        raw.each do |stream_and_entries|
          stream, pairs = stream_and_entries
          Array(pairs).each do |pair|
            id, fields = pair
            entries << Entry.new(stream.to_s, id, fields_to_hash(fields))
          end
        end
        return entries
      end

      []
    end

    def fields_to_hash(fields)
      return fields if fields.is_a?(Hash)
      Hash[*Array(fields)]
    end
  end
end