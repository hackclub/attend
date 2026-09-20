class RegistrationCorrectionsController < ApplicationController
  SECTIONS = %w[contact health emergency guardian support].freeze

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  before_action :authenticate_user!
  before_action :load_participant_event
  before_action :load_section
  before_action :load_records

  def edit
  end

  def update
    case @section
    when "contact" then update_contact
    when "health" then update_health
    when "emergency" then update_emergency
    else
      redirect_to edit_dashboard_event_correction_path(@participant_event, section: @section)
    end
  end

  private

  def render_not_found
    head :not_found
  end

  def load_participant_event
    @participant_event = current_user.participant.participant_events.includes(:event).find(params[:participant_event_id])
    authorize @participant_event, :update?
    @participant = @participant_event.participant
    @event = @participant_event.event
  end

  def load_section
    @section = params[:section].to_s
    raise ActiveRecord::RecordNotFound unless SECTIONS.include?(@section)
    if @section == "guardian" && !@participant_event.guardian_replacement_eligible?
      raise ActiveRecord::RecordNotFound
    end
  end

  def load_records
    @medical = @participant_event.medical || @participant_event.build_medical
    @dietary = @participant_event.dietary || @participant_event.build_dietary
    @accessibility = @participant_event.accessibility || @participant_event.build_accessibility
    @emergency_contact = @participant_event.emergency_contacts.by_priority.first ||
      @participant_event.emergency_contacts.build(priority: 1)
    @guardian_link = @participant_event.guardian_participant_events.includes(:guardian).first
    @change_requests = policy_scope(RegistrationChangeRequest)
      .where(participant_event: @participant_event)
      .pending_first
  end

  def update_contact
    if @participant.update(contact_params)
      RegistrationCorrectionNotifications.direct_update(@participant_event, section: :contact)
      redirect_to dashboard_event_path(@participant_event), notice: "Contact information updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def update_health
    @medical.assign_attributes(health_medical_params)
    @dietary.assign_attributes(health_dietary_params)
    @accessibility.assign_attributes(health_accessibility_params)
    records = [ @medical, @dietary, @accessibility ]

    if records.map(&:valid?).all?
      ActiveRecord::Base.transaction { records.each(&:save!) }
      RegistrationCorrectionNotifications.direct_update(@participant_event, section: :health)
      redirect_to dashboard_event_path(@participant_event), notice: "Health information updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def update_emergency
    if @participant_event.requires_guardian?
      redirect_to dashboard_event_path(@participant_event), alert: "Guardian-managed emergency contacts must be changed by event staff."
    elsif @emergency_contact.update(emergency_contact_params)
      RegistrationCorrectionNotifications.direct_update(@participant_event, section: :emergency)
      redirect_to dashboard_event_path(@participant_event), notice: "Emergency contact updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def contact_params
    params.require(:participant).permit(
      :preferred_name, :pronouns, :email, :phone, :address_line_1, :address_line_2,
      :city, :state, :postal_code, :country_of_residence, :tshirt_size
    )
  end

  def health_medical_params
    params.fetch(:medical, {}).permit(:allergies, :medical_conditions, :medications, :allergy_severity,
      :emergency_action_plan, :additional_notes,
      :has_anaphylaxis_risk, :requires_refrigeration)
  end

  def health_dietary_params
    params.fetch(:dietary, {}).permit(:diet_type, :intolerances, :life_threatening_allergies)
  end

  def health_accessibility_params
    params.fetch(:accessibility, {}).permit(:has_adhd, :has_dyslexia, :has_autism,
      :neurodivergent_notes, :uses_wheelchair, :step_free_required, :needs_captioning,
      :needs_large_print, :needs_sign_language, :other_needs, :mobility_needs,
      :sensory_needs, :communication_needs, :religious_practices,
      :distance_limitations, :unavailable_times, :light_sensitivity,
      :noise_sensitivity, :prayer_space_required, :requires_private_space,
      :strobe_sensitivity)
  end

  def emergency_contact_params
    params.require(:emergency_contact).permit(:name, :relationship, :phone, :email)
  end
end
