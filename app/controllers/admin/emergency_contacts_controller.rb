module Admin
  class EmergencyContactsController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event
    before_action :authorize_safeguarding
    before_action :set_emergency_contact, only: [ :edit, :update, :destroy ]

    def new
      @emergency_contact = EmergencyContact.new(
        priority: next_priority,
        guardian_participant_event_id: params[:guardian_participant_event_id]
      )
    end

    def create
      @emergency_contact = EmergencyContact.new(emergency_contact_params)
      assign_owner(@emergency_contact)

      if @emergency_contact.save
        redirect_to safeguarding_admin_event_participant_path(current_event, @participant_event),
          notice: "Emergency contact added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      attrs = emergency_contact_params
      @emergency_contact.assign_attributes(attrs)
      assign_owner(@emergency_contact)

      if @emergency_contact.save
        redirect_to safeguarding_admin_event_participant_path(current_event, @participant_event),
          notice: "Emergency contact updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @emergency_contact.destroy
      redirect_to safeguarding_admin_event_participant_path(current_event, @participant_event),
        notice: "Emergency contact removed."
    end

    private

    def set_participant_event
      @participant_event = current_event.participant_events.find(params[:participant_id])
    end

    def authorize_safeguarding
      authorize @participant_event, :update_safeguarding?
    end

    def set_emergency_contact
      @emergency_contact = scoped_emergency_contacts.find(params[:id])
    end

    def scoped_emergency_contacts
      EmergencyContact.left_joins(:guardian_participant_event).where(
        "emergency_contacts.participant_event_id = :pe_id OR guardian_participant_events.participant_event_id = :pe_id",
        pe_id: @participant_event.id
      )
    end

    def emergency_contact_params
      params.require(:emergency_contact).permit(
        :name, :relationship, :phone, :email, :priority, :guardian_participant_event_id
      )
    end

    def assign_owner(contact)
      gpe_id = contact.guardian_participant_event_id.presence
      if gpe_id && @participant_event.guardian_participant_events.exists?(id: gpe_id)
        contact.participant_event = nil
      else
        contact.guardian_participant_event = nil
        contact.participant_event = @participant_event
      end
    end

    def next_priority
      (scoped_emergency_contacts.maximum(:priority) || 0) + 1
    end
  end
end
