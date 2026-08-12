class QueryCounter
  class << self
    def counter
      Thread.current[:query_counter] ||= { queries: [], cached: 0 }
    end

    def reset!
      Thread.current[:query_counter] = { queries: [], cached: 0 }
    end

    def record(sql, cached:)
      return if sql.start_with?("SCHEMA")

      if cached
        counter[:cached] += 1
      else
        counter[:queries] << sql
      end
    end

    def unique_query_count
      counter[:queries].uniq.size
    end

    def total_query_count
      counter[:queries].size
    end

    def cached_query_count
      counter[:cached]
    end
  end
end

ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
  QueryCounter.record(payload[:sql], cached: payload[:cached])
end
