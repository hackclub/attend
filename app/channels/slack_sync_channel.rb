class SlackSyncChannel < ApplicationCable::Channel
  def subscribed
    event = Event.find_by(id: params[:event_id])

    if event && current_user.can_access_event?(event)
      stream_from "slack_sync_#{event.id}"
    else
      reject
    end
  end

  def unsubscribed
  end
end
