module Support
  # Folds one ticket's thread into another so a single conversation with a contact
  # reads as one thread — e.g. a closed ticket the same person replies to weeks later.
  #
  # The source keeps existing as a tombstone pointing at the target, so old links and
  # audit history still resolve; every message it held moves to the target and is
  # stamped with where it came from.
  class MergeTickets
    class MergeError < StandardError; end

    Result = Struct.new(:target, :source, :moved_messages, :moved_notes, :reopened, keyword_init: true)

    def self.call(source:, target:, user:)
      new(source:, target:, user:).call
    end

    def initialize(source:, target:, user:)
      @source = source
      @target = target
      @user = user
    end

    def call
      validate!

      moved_messages = 0
      moved_notes = 0
      reopened = false

      Ticket.transaction do
        @source.lock!
        @target.lock!

        # Re-check under the lock: a concurrent merge may have moved either side.
        validate!

        messages = TicketMessage.where(ticket_id: @source.id)
        messages.where(merged_from_ticket_id: nil).update_all(merged_from_ticket_id: @source.id)
        moved_messages = messages.update_all(ticket_id: @target.id, updated_at: Time.current)
        moved_notes = Note.where(ticket_id: @source.id).update_all(ticket_id: @target.id, updated_at: Time.current)

        reopened = reopen_target?
        @target.update!(target_attributes(reopen: reopened))

        @source.update!(
          status: :closed,
          closed_at: @source.closed_at || Time.current,
          closed_by: @source.closed_by || @user,
          merged_into: @target,
          merged_at: Time.current,
          merged_by: @user
        )
      end

      record_merge_note(moved_messages)
      broadcast_target_thread

      Result.new(
        target: @target.reload,
        source: @source,
        moved_messages: moved_messages,
        moved_notes: moved_notes,
        reopened: reopened
      )
    end

    private

    def validate!
      raise MergeError, "A ticket can't be merged into itself." if @source.id == @target.id

      if @source.merged?
        raise MergeError, "#{short_id(@source)} was already merged into #{short_id(@source.merged_into)}."
      end

      if @target.merged?
        raise MergeError,
              "#{short_id(@target)} was merged into #{short_id(@target.merged_into)} — merge into that ticket instead."
      end

      if @source.phone_number != @target.phone_number
        raise MergeError, "Tickets can only be merged when they're with the same phone number."
      end
    end

    # The whole point of merging a fresh enquiry into an old thread is to pick the
    # conversation back up, so an open source reopens a closed target.
    def reopen_target?
      @source.open? && @target.closed?
    end

    def target_attributes(reopen:)
      attributes = {
        last_inbound_at: [ @target.last_inbound_at, @source.last_inbound_at ].compact.max,
        last_outbound_at: [ @target.last_outbound_at, @source.last_outbound_at ].compact.max,
        last_message_at: [ @target.last_message_at, @source.last_message_at ].compact.max
      }

      # Fill in context the target never got, without overwriting a triage decision
      # someone already made on it.
      attributes[:event_id] = @source.event_id if @target.event_id.blank? && @source.event_id.present?
      attributes[:assigned_to_id] = @source.assigned_to_id if @target.assigned_to_id.blank? && @source.assigned_to_id.present?
      attributes[:twilio_to_number] = @source.twilio_to_number if @target.twilio_to_number.blank? && @source.twilio_to_number.present?

      if @target.subject_type.blank? && @source.subject_type.present?
        attributes[:subject_type] = @source.subject_type
        attributes[:subject_id] = @source.subject_id
      end

      attributes.merge!(status: :open, closed_at: nil, closed_by_id: nil) if reopen

      attributes
    end

    def record_merge_note(moved_messages)
      return if @user.blank?

      Note.create!(
        ticket: @target,
        event_id: @target.event_id,
        author_user_id: @user.id,
        note_type: "ops",
        body: "Merged ticket #{short_id(@source)} into this ticket " \
              "(#{ActionController::Base.helpers.pluralize(moved_messages, 'message')})."
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Support::MergeTickets] Couldn't record merge note: #{e.message}")
    end

    # Anyone already watching the target's thread needs the newly-arrived messages
    # slotted into place, not just the people who reload the page.
    def broadcast_target_thread
      Turbo::StreamsChannel.broadcast_replace_to(
        @target,
        :messages,
        target: "ticket_#{@target.id}_messages",
        partial: "support/tickets/messages",
        locals: { ticket: @target }
      )
    rescue => e
      Rails.logger.warn("[Support::MergeTickets] Couldn't broadcast merged thread: #{e.class}: #{e.message}")
    end

    def short_id(ticket)
      "##{ticket.id.first(8)}"
    end
  end
end
