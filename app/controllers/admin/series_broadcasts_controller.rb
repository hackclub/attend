module Admin
  # One message to participants across many of a series' events at once (see
  # SeriesBroadcast). The same compose, preview and send steps as an event's
  # messages; sending creates a copy on each event's messages page, which is
  # where per-event delivery detail, retries and late sends live.
  class SeriesBroadcastsController < BaseController
    HELD_FOR_REVIEW = "This broadcast looks like it might be marketing, spam, or not about the events, " \
      "so it's waiting for a Hack Club admin to review it before it goes out.".freeze
    EDITABLE_ONLY = "This broadcast has already been sent, so it can't be changed.".freeze

    global_page
    before_action :set_series
    before_action :set_broadcast, only: [ :show, :edit, :update, :destroy, :preview, :send_now, :cancel ]

    def index
      authorize SeriesBroadcast.new(event_series: @series)

      @broadcasts = @series.series_broadcasts.includes(:sent_by_user).recent.to_a
      @totals = SeriesBroadcast.totals_for(@broadcasts.map(&:id))
    end

    def show
      @messages = @broadcast.messages.includes(:event).to_a
        .sort_by { |message| [ message.event.starts_at || Time.current, message.event.name.to_s ] }
      @skipped_events = Event.where(id: @broadcast.skipped_event_ids).order(:starts_at).to_a
      @totals = @broadcast.totals
      @target_event_count = @broadcast.target_events.count unless @broadcast.sent_at
    end

    def new
      @broadcast = SeriesBroadcast.new(
        event_series: @series,
        audience: "confirmed_attendees",
        channels: [ "email" ],
        event_scope: "upcoming",
        body: ""
      )
      authorize @broadcast
      load_series_events
    end

    def create
      @broadcast = SeriesBroadcast.new(broadcast_params)
      @broadcast.event_series = @series
      @broadcast.sent_by_user = current_user
      @broadcast.status = :draft
      authorize @broadcast

      if @broadcast.save
        redirect_to preview_admin_series_broadcast_path(@series, @broadcast)
      else
        load_series_events
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      return redirect_to(admin_series_broadcast_path(@series, @broadcast), alert: EDITABLE_ONLY) unless editable?

      load_series_events
    end

    def update
      return redirect_to(admin_series_broadcast_path(@series, @broadcast), alert: EDITABLE_ONLY) unless editable?

      if @broadcast.update(broadcast_params)
        redirect_to preview_admin_series_broadcast_path(@series, @broadcast)
      else
        load_series_events
        render :edit, status: :unprocessable_entity
      end
    end

    def preview
      return redirect_to(admin_series_broadcast_path(@series, @broadcast), alert: EDITABLE_ONLY) unless editable?

      @events = @broadcast.target_events.order(:starts_at).to_a
      @counts = @broadcast.recipient_counts_by_event
      @total_count = @counts.values.sum
      @reached_events = @events.select { |event| @counts[event.id].to_i.positive? }
      @recipients = @broadcast.preview_recipients(limit: 20).load

      # The channel previews fill placeholders in for one real recipient at
      # one real event, so staff see what a person will actually get.
      first = @recipients.first
      @preview_event = first.respond_to?(:event) ? first.event : @reached_events.first
      @preview_recipient = first.respond_to?(:participant) ? first.participant : first
    end

    def destroy
      if @broadcast.sending? || @broadcast.completed?
        redirect_to admin_series_broadcast_path(@series, @broadcast), alert: "A broadcast that has been sent can't be deleted."
        return
      end

      @broadcast.destroy!
      redirect_to admin_series_broadcasts_path(@series), notice: "Draft deleted."
    end

    def send_now
      unless editable?
        redirect_to admin_series_broadcast_path(@series, @broadcast), alert: "This broadcast has already been sent."
        return
      end

      if @broadcast.body.blank?
        redirect_to edit_admin_series_broadcast_path(@series, @broadcast), alert: "Message body cannot be empty."
        return
      end

      if @broadcast.scheduled_at.present? && @broadcast.scheduled_at > Time.current
        if @broadcast.schedule!(sender: current_user)
          redirect_to admin_series_broadcast_path(@series, @broadcast),
            notice: "Broadcast scheduled for #{helpers.cs_absolute_time(@broadcast.scheduled_at)}."
        elsif @broadcast.errors.any?
          redirect_to edit_admin_series_broadcast_path(@series, @broadcast), alert: @broadcast.errors.full_messages.to_sentence
        else
          redirect_to admin_series_broadcast_path(@series, @broadcast), alert: HELD_FOR_REVIEW
        end
      elsif @broadcast.send!(sender: current_user)
        redirect_to admin_series_broadcast_path(@series, @broadcast),
          notice: "Sending to each event. Its copies appear below as they go out."
      elsif @broadcast.errors.any?
        redirect_to edit_admin_series_broadcast_path(@series, @broadcast), alert: @broadcast.errors.full_messages.to_sentence
      elsif @broadcast.pending_review?
        redirect_to admin_series_broadcast_path(@series, @broadcast), alert: HELD_FOR_REVIEW
      else
        # A double-click or a concurrent send beat us to it.
        redirect_to admin_series_broadcast_path(@series, @broadcast), alert: "This broadcast has already been sent."
      end
    end

    def cancel
      was_held = @broadcast.pending_review?
      unless @broadcast.cancel!
        redirect_to admin_series_broadcast_path(@series, @broadcast),
          alert: "Only scheduled broadcasts, or ones waiting for review, can be cancelled."
        return
      end

      redirect_to admin_series_broadcast_path(@series, @broadcast),
        notice: was_held ? "Broadcast withdrawn from review and cancelled." : "Scheduled broadcast has been cancelled."
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:series_slug])
    end

    def set_broadcast
      @broadcast = @series.series_broadcasts.find(params[:id])
      authorize @broadcast
    end

    def editable?
      @broadcast.draft? || @broadcast.scheduled?
    end

    def load_series_events
      @series_events = @series.events.order(:starts_at).to_a
    end

    def broadcast_params
      permitted = params.require(:series_broadcast)
        .permit(:subject, :body, :audience, :event_scope, :scheduled_at, channels: [], selected_event_ids: [])

      permitted[:channels] = Array(permitted[:channels]).reject(&:blank?) if permitted.key?(:channels)
      if permitted.key?(:selected_event_ids) || permitted.key?(:event_scope)
        ids = Array(permitted[:selected_event_ids]).reject(&:blank?).uniq
        scope = permitted.fetch(:event_scope) { @broadcast&.event_scope }
        permitted[:selected_event_ids] = scope == "selected" ? ids : []
      end
      permitted
    end
  end
end
