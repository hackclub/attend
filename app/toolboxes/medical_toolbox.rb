class MedicalToolbox < ApplicationToolbox
  # Sensitive: medical, dietary, and accessibility records. Full clinical detail is
  # visible only to event_admin/safeguarding_lead; ops sees a limited view.

  tool "Show a participant's medical, dietary, and accessibility records. " \
       "Detail level follows your event role.", access: :read, scope: "medical:read" do
    param :participant_event_id, :string, "ParticipantEvent ID"
  end
  def show
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    Current.event = @participant_event.event
    authorize! @participant_event, :view_medical?

    medical = @participant_event.medical
    full = medical && Pundit.policy(current_user, medical).show_full_details?

    render json: {
      participant_event_id: @participant_event.id,
      detail_level: full ? "full" : "limited",
      medical: serialize_medical(medical, full: full),
      dietary: serialize_dietary(@participant_event.dietary),
      accessibility: serialize_accessibility(@participant_event.accessibility)
    }
  end

  tool "Update a participant's medical record.", access: :write, scope: "medical:write" do
    param :participant_event_id, :string, "ParticipantEvent ID"
    param :allergies, :string, "Allergies", optional: true
    param :allergy_severity, :string, "Allergy severity", optional: true
    param :has_anaphylaxis_risk, :boolean, "At risk of anaphylaxis", optional: true
    param :medical_conditions, :string, "Medical conditions", optional: true
    param :medications, :string, "Medications", optional: true
    param :emergency_action_plan, :string, "Emergency action plan", optional: true
    param :additional_notes, :string, "Additional notes", optional: true
  end
  def update
    @participant_event = ParticipantEvent.find(params[:participant_event_id])
    Current.event = @participant_event.event
    authorize! @participant_event, :update_medical?

    @medical = @participant_event.medical || @participant_event.build_medical
    @medical.assign_attributes(params.permit(:allergies, :allergy_severity, :has_anaphylaxis_risk,
                                             :medical_conditions, :medications,
                                             :emergency_action_plan, :additional_notes).to_h)
    @medical.last_updated_by = current_user if @medical.respond_to?(:last_updated_by=)
    @medical.save!
    render json: { medical: serialize_medical(@medical, full: true) }
  end

  private

  def serialize_medical(m, full:)
    return nil if m.nil?

    base = { allergies: m.allergies, allergy_severity: m.allergy_severity,
             has_anaphylaxis_risk: m.has_anaphylaxis_risk, requires_refrigeration: m.requires_refrigeration }
    return base unless full

    base.merge(medical_conditions: m.medical_conditions, medications: m.medications,
               emergency_action_plan: m.emergency_action_plan, additional_notes: m.additional_notes,
               last_updated_by: m.last_updated_by&.display_name_or_fallback)
  end

  def serialize_dietary(d)
    return nil if d.nil?

    { diet_type: d.diet_type, life_threatening_allergies: d.life_threatening_allergies,
      intolerances: d.intolerances, cross_contamination_risk: d.cross_contamination_risk, notes: d.notes }
  end

  def serialize_accessibility(a)
    return nil if a.nil?

    { mobility_needs: a.mobility_needs, uses_wheelchair: a.uses_wheelchair, step_free_required: a.step_free_required,
      sensory_needs: a.sensory_needs, communication_needs: a.communication_needs,
      needs_captioning: a.needs_captioning, needs_sign_language: a.needs_sign_language,
      religious_practices: a.religious_practices, prayer_space_required: a.prayer_space_required,
      other_needs: a.other_needs }
  end
end
