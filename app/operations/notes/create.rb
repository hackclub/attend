module Notes
  # Adds a staff note to a registration, on every surface.
  #
  # NotePolicy#create? decides: any role on the event may write a note, and a
  # restricted one needs an event admin or safeguarding lead. The restricted
  # rule is checked first and by name so the admin UI and the API can keep
  # telling the author exactly why they were refused.
  #
  # `attributes` is whatever the surface accepts (the API takes no
  # visible_to_roles and defaults note_type and sensitivity; the admin form and
  # MCP pass all four) — the operation doesn't widen any of them.
  class Create < ApplicationOperation
    audit_actions :record_create

    PERMITTED = %i[body note_type sensitivity visible_to_roles].freeze
    RESTRICTED_MESSAGE = "Only event admins and safeguarding leads can add restricted notes.".freeze

    def initialize(context, participant_event:, attributes:)
      super(context)
      @participant_event = participant_event
      @attributes = attributes.to_h.symbolize_keys.slice(*PERMITTED)
    end

    def precheck
      if note.restricted? && !Note.restricted_visible_to?(context.user, note.event)
        return failure(:restricted_not_allowed, RESTRICTED_MESSAGE, record: note)
      end

      authorize!(note, :create?)
      nil
    end

    private

    def note
      @note ||= @participant_event.notes.build(@attributes).tap do |note|
        note.event = @participant_event.event
        note.author = context.user
      end
    end

    def perform
      note.save!
      audit!(:record_create, note, metadata: { participant_event_id: @participant_event.id })
      success(note)
    end
  end
end
