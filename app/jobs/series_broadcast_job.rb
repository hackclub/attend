# Fans a SeriesBroadcast out into one Message per event (see
# SeriesBroadcast#fan_out!). Kept out of the request: a series can have
# hundreds of events and thousands of recipients. Safe to retry.
class SeriesBroadcastJob < ApplicationJob
  queue_as :default

  def perform(series_broadcast_id:)
    SeriesBroadcast.find_by(id: series_broadcast_id)&.fan_out!
  end
end
