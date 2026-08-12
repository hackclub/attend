Rails.application.config.filter_parameters += [
  # Authentication & security
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,

  # Identity fields
  :name, :first_name, :last_name, :legal_first_name, :legal_last_name, :preferred_name,
  :given_name, :family_name, :pronouns,

  # Contact information
  :phone, :phone_number, :address, :slack_id,

  # Dates
  :date_of_birth, :birthdate,

  # Health & medical
  :allergies, :medical_conditions, :medications, :emergency_action_plan,
  :intolerances, :life_threatening_allergies,
  :has_anaphylaxis_risk, :requires_refrigeration, :additional_notes,
  :diet_type, :cross_contamination_risk,

  # Accessibility & neurodivergence
  :mobility_needs, :sensory_needs, :communication_needs, :other_needs,
  :has_adhd, :has_dyslexia, :has_autism, :neurodivergent_notes,
  :uses_wheelchair, :step_free_required,
  :needs_captioning, :needs_large_print, :needs_sign_language,

  # Religious & cultural
  :religious_practices,

  # Emergency contact
  :authorized_pickup_adults, :other_instructions, :relationship,

  # Safeguarding
  :high_support_notes, :high_support_flag, :freedom_waiver_granted, :can_leave_unaccompanied,
  :summary, :details, :actions_taken, :body,

  # Legal
  :code_of_conduct_signature,

  # Catch-all for notes fields
  /_notes\z/
]
