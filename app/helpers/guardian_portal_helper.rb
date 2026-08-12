module GuardianPortalHelper
  CONSENT_TYPE_LABELS = {
    "event_consent" => "Event Participation Consent",
    "medical_release" => "Medical Release",
    "code_of_conduct" => "Code of Conduct Agreement",
    "media" => "Media Release",
    "waiver" => "Liability Waiver",
    "participant_agreement" => "Participant Agreement",
    "freedom_waiver" => "Freedom Waiver"
  }.freeze

  CONSENT_TYPE_DESCRIPTIONS = {
    "event_consent" => "Permission for your child to participate in this event.",
    "medical_release" => "Authorization for emergency medical treatment if needed.",
    "code_of_conduct" => "Agreement to follow the event's code of conduct.",
    "media" => "Permission to use photos/videos from the event.",
    "waiver" => "Liability waiver and release of claims.",
    "participant_agreement" => "Agreement to the terms of participation.",
    "freedom_waiver" => "Permission for your child to leave the event venue unsupervised."
  }.freeze

  def consent_type_label(consent_type)
    CONSENT_TYPE_LABELS[consent_type.to_s] || consent_type.to_s.titleize
  end

  def consent_type_description(consent_type)
    CONSENT_TYPE_DESCRIPTIONS[consent_type.to_s] || ""
  end

  def consent_signing_url_for_guardian(consent)
    return nil unless consent.waiver? || consent.freedom_waiver?
    consent.guardian_signing_url
  end

  def consent_status_for_guardian(consent)
    if consent.waiver? || consent.freedom_waiver?
      if consent.freedom_waiver?
        # Freedom waiver is parent-only, so check signed status
        if consent.signed?
          :signed
        elsif consent.guardian_signing_url.present?
          :ready
        else
          :preparing
        end
      else
        # Regular waiver requires both guardian and participant
        if consent.guardian_signed?
          :signed
        elsif consent.guardian_signing_url.present?
          :ready
        else
          :preparing
        end
      end
    else
      consent.signed? ? :signed : :pending
    end
  end
end
