module Admin
  class MessagesController < BaseController
    before_action :require_event_selected
    before_action :set_message, only: [ :show, :edit, :update, :destroy, :preview, :send_now, :cancel, :retry_failed, :retry_delivery ]

    def index
      authorize current_event, :update?

      @messages = current_event.messages
        .includes(:sent_by_user)
        .order(created_at: :desc)
    end

    def show
      authorize current_event, :update?

      @deliveries = @message.message_deliveries
        .includes(:participant_event, :guardian)
        .order(:status, :created_at)
    end

    def new
      authorize current_event, :update?

      @message = current_event.messages.new(
        audience: "confirmed_attendees",
        channels: [ "slack" ],
        body: ""
      )
    end

    def create
      authorize current_event, :update?

      @message = current_event.messages.new(message_params)
      @message.sent_by_user = current_user
      @message.status = :draft

      if @message.save
        respond_to do |format|
          format.html { redirect_to preview_admin_event_message_path(current_event, @message) }
          format.json do
            render json: {
              success: true,
              saved_at: Time.current.iso8601,
              update_url: admin_event_message_path(current_event, @message, format: :json),
              form_action: admin_event_message_path(current_event, @message),
              edit_url: edit_admin_event_message_path(current_event, @message)
            }
          end
        end
      else
        respond_to do |format|
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: { success: false, errors: @message.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def edit
      authorize current_event, :update?

      unless @message.draft? || @message.scheduled?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "Cannot edit a message that has already been sent."
      end
    end

    def update
      authorize current_event, :update?

      unless @message.draft? || @message.scheduled?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "Cannot edit a message that has already been sent."
        return
      end

      if @message.update(message_params)
        respond_to do |format|
          format.html { redirect_to preview_admin_event_message_path(current_event, @message) }
          format.json { render json: { success: true, saved_at: Time.current.iso8601 } }
        end
      else
        respond_to do |format|
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: { success: false, errors: @message.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end

    def preview
      authorize current_event, :update?

      unless @message.draft? || @message.scheduled?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "Cannot preview a message that has already been sent."
        return
      end

      @recipients = @message.preview_recipients(limit: 20)
      @total_count = @message.recipient_count_estimate
    end

    def destroy
      authorize current_event, :update?

      if @message.sending? || @message.completed?
        redirect_to admin_event_messages_path(current_event),
          alert: "Cannot delete a message that has been sent."
        return
      end

      @message.destroy
      redirect_to admin_event_messages_path(current_event), notice: "Draft deleted."
    end

    def send_now
      authorize current_event, :update?

      unless @message.draft? || @message.scheduled?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "This message has already been sent."
        return
      end

      if @message.body.blank?
        redirect_to edit_admin_event_message_path(current_event, @message),
          alert: "Message body cannot be empty."
        return
      end

      if @message.scheduled_at.present? && @message.scheduled_at > Time.current
        @message.update!(status: :scheduled)
        redirect_to admin_event_message_path(current_event, @message),
          notice: "Message scheduled for #{@message.scheduled_at.strftime("%B %d, %Y at %l:%M %p")}."
      else
        send_message(@message)
        redirect_to admin_event_message_path(current_event, @message),
          notice: "Message is being sent to #{@message.recipient_count} recipients."
      end
    end

    def cancel
      authorize current_event, :update?

      unless @message.scheduled?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "Only scheduled messages can be cancelled."
        return
      end

      @message.update!(status: :cancelled)
      redirect_to admin_event_message_path(current_event, @message),
        notice: "Scheduled message has been cancelled."
    end

    def retry_failed
      authorize current_event, :update?

      failed_count = @message.message_deliveries.failed.count
      if failed_count.zero?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "No failed deliveries to retry."
        return
      end

      @message.message_deliveries.failed.update_all(status: "pending", error_message: nil)
      @message.update!(status: :sending)

      MessageDeliveryJob.perform_later(message_id: @message.id, retry_failed_only: true)

      redirect_to admin_event_message_path(current_event, @message),
        notice: "Retrying #{failed_count} failed deliveries..."
    end

    def retry_delivery
      authorize current_event, :update?

      delivery = @message.message_deliveries.find(params[:delivery_id])

      unless delivery.failed?
        redirect_to admin_event_message_path(current_event, @message),
          alert: "This delivery hasn't failed."
        return
      end

      delivery.update!(status: :pending, error_message: nil)
      SingleDeliveryJob.perform_later(delivery_id: delivery.id)

      redirect_to admin_event_message_path(current_event, @message),
        notice: "Retrying delivery to #{delivery.recipient_name}..."
    end

    private

    def set_message
      @message = current_event.messages.find(params[:id])
    end

    def message_params
      permitted = params.require(:message).permit(:subject, :body, :audience, :scheduled_at, channels: [], participant_event_ids: [], group_ids: [])

      group_ids = (permitted.delete(:group_ids) || []).reject(&:blank?)
      pe_ids = permitted.delete(:participant_event_ids)

      filters = {}
      if permitted[:audience] == "specific_participants" && pe_ids.present?
        filters["participant_event_ids"] = pe_ids.reject(&:blank?)
      end
      filters["group_ids"] = group_ids if group_ids.any?

      permitted[:audience_filters] = filters
      permitted
    end

    def send_message(message)
      recipients = message.recipients

      if message.guardian_audience?
        recipients.find_each do |guardian|
          message.channels.each do |channel|
            next unless can_deliver_to_guardian?(guardian, channel)

            message.message_deliveries.create!(
              guardian: guardian,
              channel: channel,
              recipient_email: guardian.email,
              recipient_phone: guardian.phone,
              status: :pending
            )
          end
        end
      else
        recipients.find_each do |participant_event|
          message.channels.each do |channel|
            next unless can_deliver_to_participant?(participant_event, channel)

            message.message_deliveries.create!(
              participant_event: participant_event,
              channel: channel,
              recipient_email: participant_event.participant.email,
              recipient_phone: participant_event.participant.phone,
              recipient_slack_id: participant_event.participant.slack_user_id,
              status: :pending
            )
          end
        end
      end

      message.update!(
        status: :sending,
        recipient_count: message.message_deliveries.select(:participant_event_id, :guardian_id).distinct.count,
        sent_at: Time.current
      )

      MessageDeliveryJob.perform_later(message_id: message.id)
    end

    def can_deliver_to_participant?(participant_event, channel)
      case channel.to_s
      when "slack"
        participant_event.participant.slack_user_id.present?
      when "email"
        participant_event.participant.email.present?
      when "sms"
        participant_event.participant.phone.present?
      else
        false
      end
    end

    def can_deliver_to_guardian?(guardian, channel)
      case channel.to_s
      when "slack"
        false
      when "email"
        guardian.email.present?
      when "sms"
        guardian.phone.present?
      else
        false
      end
    end
  end
end
