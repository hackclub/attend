module Api
  module V1
    # Organizer broadcasts for the mobile app: compose, preview, schedule and
    # send a Message, and follow its deliveries. The rules are
    # Admin::MessagesController's, answered as JSON instead of redirects.
    class MessagesController < BaseController
      include Pundit::Authorization
      include Api::V1::ApiAuditing

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      before_action :reject_api_key_auth
      before_action :set_paper_trail_whodunnit
      before_action :set_event
      before_action :set_message, except: [ :index, :options, :create ]

      def index
        messages = @event.messages.includes(:sent_by_user).order(created_at: :desc)
        render json: { messages: messages.map { |message| message_summary_json(message) } }
      end

      # The composer's pick lists: audiences, channels, groups, participants.
      def options
        groups = @event.groups_enabled? ? @event.groups.ordered : Group.none

        render json: {
          audiences: Message::AUDIENCES
            .reject { |key, _| key == :attendees_in_groups && !@event.groups_enabled? }
            .map { |key, label| { value: key.to_s, label: label } },
          channels: Message::CHANNELS.map do |key, label|
            sms_disabled = key == :sms && !Setting.twilio_enabled?
            {
              value: key.to_s,
              label: label,
              disabled: sms_disabled,
              description: (key == :slack ? "Attendees only" : (sms_disabled ? "Disabled in settings" : nil))
            }
          end,
          groups: groups.map { |g| { id: g.id, name: g.name, color: g.normalized_color } },
          participants: @event.participant_events.includes(:participant).order("participants.legal_first_name").map do |pe|
            { id: pe.id, name: pe.participant.display_name, email: pe.participant.email, status: pe.status }
          end,
          defaults: { audience: "confirmed_attendees", channels: [ "slack" ] }
        }
      end

      def show
        render json: { message: message_json(@message) }
      end

      def create
        message = @event.messages.new(message_params)
        message.sent_by_user = current_user
        message.status = :draft
        # The column is NOT NULL but the model doesn't validate it: a draft
        # saved before anything is typed starts empty, as on the web.
        message.body ||= ""

        if message.save
          audit_api_change!(:record_create, message)
          render json: { message: message_json(message) }, status: :created
        else
          render_validation_errors(message)
        end
      end

      def update
        return render_error("Cannot edit a message that has already been sent.") unless editable?

        if @message.update(message_params)
          audit_api_change!(:record_update, @message)
          render json: { message: message_json(@message) }
        else
          render_validation_errors(@message)
        end
      end

      def destroy
        if @message.sending? || @message.completed?
          return render_error("Cannot delete a message that has been sent.")
        end

        @message.destroy
        audit_api_change!(:record_destroy, @message, changed_fields: {})
        render json: { notice: "Draft deleted." }
      end

      # Step 2 of the composer: who it reaches and how each channel renders.
      def preview
        return render_error("Cannot preview a message that has already been sent.") unless editable?

        recipients = @message.preview_recipients(limit: 20)
        sms_text = @message.body_as_plain

        render json: {
          preview: {
            total_count: @message.recipient_count_estimate,
            recipient_names: recipients.map { |r| r.respond_to?(:participant) ? r.participant.display_name : r.full_name },
            audience_label: @message.audience_label,
            channel_labels: @message.channel_labels,
            channels: @message.channels,
            slack_text: @message.channels.include?("slack") ? @message.body_as_slack : nil,
            email_subject: @message.channels.include?("email") ? (@message.subject.presence || "You have a new message from #{@event.name}") : nil,
            body_html: @message.body_as_html,
            sms_text: @message.channels.include?("sms") ? sms_text : nil,
            sms_length: sms_text.length,
            sms_segments: (sms_text.length / 160.0).ceil,
            scheduled_at: @message.scheduled_at&.iso8601,
            scheduled_in_future: scheduled_in_future?
          }
        }
      end

      def send_now
        return render_error("This message has already been sent.") unless editable?
        return render_error("Message body cannot be empty.") if @message.body.blank?

        if scheduled_in_future?
          @message.update!(status: :scheduled)
          audit_api_change!(:send_now, @message)
          render json: { message: message_json(@message), notice: "Message scheduled for #{@message.local_scheduled_at.strftime("%B %d, %Y at %l:%M %p %Z")}." }
        elsif @message.send!
          audit_api_change!(:send_now, @message)
          render json: { message: message_json(@message.reload), notice: "Message is being sent to #{@message.recipient_count} recipients." }
        else
          # A double tap or a concurrent send beat us; nothing changed.
          render_error("This message has already been sent.")
        end
      end

      def cancel
        return render_error("Only scheduled messages can be cancelled.") unless @message.scheduled?

        @message.update!(status: :cancelled)
        audit_api_change!(:cancel, @message)
        render json: { message: message_json(@message), notice: "Scheduled message has been cancelled." }
      end

      def retry_failed
        failed_count = @message.message_deliveries.failed.count
        return render_error("No failed deliveries to retry.") if failed_count.zero?

        @message.message_deliveries.failed.update_all(status: "pending", error_message: nil)
        @message.update!(status: :sending)
        MessageDeliveryJob.perform_later(message_id: @message.id)
        audit_api_change!(:retry_failed, @message)

        render json: { message: message_json(@message), notice: "Retrying #{failed_count} failed deliveries..." }
      end

      def retry_delivery
        delivery = @message.message_deliveries.find(params[:delivery_id])
        return render_error("This delivery hasn't failed.") unless delivery.failed?

        delivery.update!(status: :pending, error_message: nil)
        SingleDeliveryJob.perform_later(delivery_id: delivery.id)
        audit_api_change!(:retry_delivery, @message, changed_fields: {}, metadata: { delivery_id: delivery.id })

        render json: { message: message_json(@message), notice: "Retrying delivery to #{delivery.recipient_name}..." }
      end

      def send_to_new_recipients
        unless @message.can_send_to_new_recipients?
          return render_error(@message.sent_at.blank? ? "This message hasn't been sent yet." : "This message is still sending.")
        end

        added = @message.send_to_new_recipients!
        audit_api_change!(:send_to_new_recipients, @message, changed_fields: {}, metadata: { added: added })
        notice = added.zero? ? "No one new matches this audience." : "Sending to #{added} new #{"recipient".pluralize(added)}..."

        render json: { message: message_json(@message.reload), notice: notice }
      end

      private

      # A message is attributed to the person who sends it.
      def reject_api_key_auth
        return unless api_key_request?

        render json: { error: "API key is not authorized for messages" }, status: :forbidden
      end

      def set_paper_trail_whodunnit
        PaperTrail.request.whodunnit = current_user&.id
      end

      # The web composer is behind EventPolicy#update?: anyone with access to
      # the event.
      def set_event
        @event = Event.find_by(id: params[:event_id]) || Event.find_by!(slug: params[:event_id])
        Current.event = @event
        authorize @event, :update?
      end

      def set_message
        @message = @event.messages.find(params[:id])
      end

      def editable?
        @message.draft? || @message.scheduled?
      end

      def scheduled_in_future?
        @message.scheduled_at.present? && @message.scheduled_at > Time.current
      end

      # Same shape the web form posts; participant and group picks fold into
      # audience_filters exactly as Admin::MessagesController#message_params.
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

      def render_validation_errors(record)
        render json: { error: record.errors.full_messages.to_sentence, errors: record.errors.full_messages },
          status: :unprocessable_entity
      end

      def message_summary_json(message)
        {
          id: message.id,
          subject: message.subject,
          status: message.status,
          audience: message.audience,
          audience_label: message.audience_label,
          channels: message.channels,
          recipient_count: message.recipient_count,
          sent_count: message.sent_count,
          failed_count: message.failed_count,
          scheduled_at: message.scheduled_at&.iso8601,
          sent_at: message.sent_at&.iso8601,
          created_at: message.created_at.iso8601,
          sent_by: message.sent_by_user&.display_name_or_fallback,
          preview_text: message.body_as_plain.truncate(140)
        }
      end

      def message_json(message)
        deliveries = message.message_deliveries.includes(:guardian, participant_event: { participant: :user }).order(:status, :created_at)
        show_phone = current_user.can_view_participant_pii?(@event)
        new_recipient_count = message.can_send_to_new_recipients? ? message.new_recipients.count : 0
        editable = message.draft? || message.scheduled?

        message_summary_json(message).merge(
          body: message.body,
          body_html: message.body_as_html,
          participant_event_ids: message.audience_filters["participant_event_ids"] || [],
          group_ids: message.audience_filters["group_ids"] || [],
          opened_count: message.channels.include?("email") ? message.message_deliveries.for_channel("email").read.count : nil,
          pending_count: message.message_deliveries.pending.count,
          new_recipient_count: new_recipient_count,
          recipients: deliveries.group_by { |d| d.participant_event_id || d.guardian_id }.map do |recipient_id, group|
            first = group.first
            {
              id: recipient_id,
              name: first.recipient_name,
              kind: first.participant_event.present? ? "attendee" : "guardian",
              catch_up: first.catch_up?,
              deliveries: group.map do |delivery|
                {
                  id: delivery.id,
                  channel: delivery.channel,
                  status: delivery.status,
                  # An SMS identifier is a phone number, which PII-restricted
                  # roles don't get; an email or Slack ID is fine for them.
                  recipient_identifier: (show_phone || delivery.channel != "sms") ? delivery.recipient_identifier : nil,
                  error_message: delivery.error_message,
                  delivered_at: delivery.delivered_at&.iso8601,
                  read_at: delivery.read_at&.iso8601
                }
              end
            }
          end,
          permissions: {
            edit: editable,
            send_now: editable,
            destroy: !(message.sending? || message.completed?),
            cancel: message.scheduled?,
            retry_failed: message.failed_count.to_i > 0,
            send_to_new_recipients: new_recipient_count > 0
          }
        )
      end
    end
  end
end
