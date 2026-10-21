module Admin
  class MessagesController < BaseController
    before_action :require_event_selected
    before_action :set_message, only: [ :show, :edit, :update, :destroy, :preview, :send_now, :cancel, :retry_failed, :retry_delivery, :send_to_new_recipients ]

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
      @new_recipient_count = @message.can_send_to_new_recipients? ? @message.new_recipients.count : 0
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
      elsif @message.send!
        redirect_to admin_event_message_path(current_event, @message),
          notice: "Message is being sent to #{@message.recipient_count} recipients."
      else
        # The lock inside send! found it already sent: a double-click or a
        # concurrent send beat us. Nothing changed, so nothing is audit-logged.
        redirect_to admin_event_message_path(current_event, @message),
          alert: "This message has already been sent."
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

      MessageDeliveryJob.perform_later(message_id: @message.id)

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

    def send_to_new_recipients
      authorize current_event, :update?

      unless @message.can_send_to_new_recipients?
        alert = @message.sent_at.blank? ? "This message hasn't been sent yet." : "This message is still sending."
        redirect_to admin_event_message_path(current_event, @message), alert: alert
        return
      end

      added = @message.send_to_new_recipients!
      notice = if added.zero?
        "No one new matches this audience."
      else
        "Sending to #{added} new #{"recipient".pluralize(added)}..."
      end

      redirect_to admin_event_message_path(current_event, @message), notice: notice
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
  end
end
