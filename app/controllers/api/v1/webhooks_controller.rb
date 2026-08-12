module Api
  module V1
    class WebhooksController < ActionController::API
      before_action :verify_webhook_signature

      def docuseal
        event_type = params[:event_type]
        submission_data = params[:data]

        case event_type
        when "submission.completed"
          handle_submission_completed(submission_data)
        when "form.completed"
          handle_form_completed(submission_data)
        when "form.viewed", "form.started"
          handle_form_viewed(submission_data)
        when "form.declined"
          handle_form_declined(submission_data)
        when "submission.expired"
          handle_submission_failed(submission_data, event_type)
        end

        head :ok
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error("Docuseal webhook: Record not found - #{e.message}")
        head :ok
      rescue StandardError => e
        Rails.logger.error("Docuseal webhook error: #{e.message}")
        head :unprocessable_entity
      end

      private

      def verify_webhook_signature
        # Accept any configured cluster secret so both hosts can deliver during the bridge.
        configured_secrets = Docuseal::HostConfig.webhook_secrets
        configured_secrets << ENV["DOCUSEAL_WEBHOOK_SECRET"] if ENV["DOCUSEAL_WEBHOOK_SECRET"].present?
        configured_secrets = configured_secrets.compact.uniq

        if configured_secrets.empty?
          Rails.logger.error("[Security] Docuseal webhook rejected: no secret configured")
          head :service_unavailable and return
        end

        provided_secret = request.headers["X-Webhook-Secret"] ||
                          request.headers["DOCUSEAL_WEBHOOK_SECRET"] ||
                          request.headers["HTTP_DOCUSEAL_WEBHOOK_SECRET"] ||
                          request.headers["X-Docuseal-Secret"]

        if provided_secret.blank?
          Rails.logger.warn("[Security] Docuseal webhook rejected: missing webhook secret header. Available headers: #{request.headers.to_h.keys.select { |k| k.start_with?('HTTP_') || k.include?('SECRET') }.join(', ')}")
          head :unauthorized and return
        end

        unless configured_secrets.any? { |s| ActiveSupport::SecurityUtils.secure_compare(provided_secret, s) }
          Rails.logger.warn("[Security] Docuseal webhook rejected: invalid secret")
          head :unauthorized
        end
      end

      def handle_submission_completed(data)
        consent = find_consent(data)
        return unless consent

        consent.update!(
          status: :signed,
          signed_at: Time.current,
          pending_on: nil,
          document_url: data["documents"]&.first&.dig("url")
        )

        check_onboarding_completion(consent)

        # Send completion notification when waiver is fully signed
        if consent.waiver?
          notify_waiver_fully_signed(consent)
        end
      end

      def handle_form_completed(data)
        consent = find_consent(data)
        return unless consent

        role = data["role"]&.downcase
        Rails.logger.info("[Docuseal] Form completed by #{role} for consent #{consent.id}, consent_type=#{consent.consent_type}, data keys=#{data.keys}")

        if role&.include?("attendee") || role&.include?("participant")
          consent.update!(
            participant_signed_at: Time.current,
            pending_on: "guardian"
          )

          # For minor waivers, resend the guardian portal invitation after teen signs
          # (guardian still needs to complete their portal before signing the waiver)
          if consent.waiver? && consent.participant_event&.requires_guardian?
            resend_guardian_portal_invitation(consent)
          end
        elsif role&.include?("guardian") || role&.include?("legal guardian") || role&.include?("parent")
          consent.update!(
            guardian_signed_at: Time.current,
            pending_on: nil
          )

          # Process freedom waiver result when guardian signs (single-signer document)
          if consent.freedom_waiver?
            process_freedom_waiver_result(consent, data)
          end

          # Send waiver completion notification when all guardian waivers are signed
          notify_waiver_completion(consent)
        end
      end

      def handle_form_viewed(data)
        consent = find_consent(data)
        return unless consent

        role = data["role"]&.downcase
        consent.update!(status: :viewed) if consent.sent?

        is_guardian_role = role&.include?("guardian") || role&.include?("legal guardian") || role&.include?("parent")
        is_participant_role = role&.include?("attendee") || role&.include?("participant")

        if consent.pending_on.blank? && is_participant_role
          consent.update!(pending_on: "participant")
        end
      end

      def handle_form_declined(data)
        consent = find_consent(data)
        return unless consent

        role = data["role"]&.downcase
        consent.update!(
          status: :failed,
          failure_reason: "declined_by_#{role}"
        )
      end

      def handle_submission_failed(data, event_type)
        consent = find_consent(data)
        return unless consent

        consent.update!(
          status: :failed,
          failure_reason: event_type
        )
      end

      def find_consent(data)
        consent_id = data.dig("metadata", "consent_id")
        return Consent.find(consent_id) if consent_id.present?

        # For form.completed, submission_id is nested under data["submission"]["id"]
        # For submission.completed, it may be at data["submission_id"] or data["id"]
        envelope_id = data["submission_id"] || data.dig("submission", "id") || data["id"]
        Consent.find_by(docuseal_envelope_id: envelope_id) if envelope_id.present?
      end

      def process_freedom_waiver_result(consent, data)
        participant_event = consent.participant_event
        return unless participant_event

        values = data["values"] || []
        Rails.logger.info("[Docuseal] Freedom waiver values received: #{values.inspect}")

        # Try to use configured field mappings first
        event = participant_event.event
        freedom_config = event.docuseal_field_mappings&.dig("freedom_waiver", "freedom_checkbox_config")

        if freedom_config.present? && freedom_config["granted_field"].present?
          # Use configured field names
          granted_field_name = freedom_config["granted_field"]
          rejected_field_name = freedom_config["rejected_field"]

          freedom_granted = values.find { |v| v["field"] == granted_field_name }&.dig("value")
          freedom_rejected = values.find { |v| v["field"] == rejected_field_name }&.dig("value")

          Rails.logger.info("[Docuseal] Using configured fields: granted=#{granted_field_name}, rejected=#{rejected_field_name}")
        else
          # Fallback to fuzzy matching for backwards compatibility
          freedom_granted = values.find { |v| v["field"]&.downcase&.include?("granted") }&.dig("value")
          freedom_rejected = values.find { |v| v["field"]&.downcase&.include?("rejected") }&.dig("value")

          Rails.logger.info("[Docuseal] Using fuzzy field matching (no configured mappings)")
        end

        # Determine if freedom was granted (checkbox is checked = true)
        granted = truthy_value?(freedom_granted)
        rejected = truthy_value?(freedom_rejected)

        # Update safeguarding info based on selection
        safeguarding_info = participant_event.safeguarding_info || participant_event.build_safeguarding_info
        safeguarding_info.update!(freedom_waiver_granted: granted && !rejected)

        Rails.logger.info("[Docuseal] Freedom waiver processed for participant_event #{participant_event.id}: granted=#{granted}, rejected=#{rejected}")
      end

      def truthy_value?(value)
        return false if value.nil?

        case value
        when true, 1
          true
        when String
          value.strip.downcase.in?(%w[true 1 on yes checked])
        else
          false
        end
      end

      def check_onboarding_completion(consent)
        participant_event = consent.participant_event
        return unless participant_event

        # Completion can be unblocked by the main waiver, freedom waiver, or a custom document
        return unless consent.signed? && (consent.waiver? || consent.freedom_waiver? || consent.custom_document?)

        if participant_event.mark_complete_if_eligible!
          Rails.logger.info("[Docuseal] Participant #{participant_event.id} marked complete after #{consent.consent_type} signed")
        end
      end

      def notify_waiver_completion(consent)
        participant_event = consent.participant_event
        unless participant_event
          Rails.logger.info("[Loops] notify_waiver_completion: no participant_event for consent #{consent.id}")
          return
        end

        guardian_participant_event = participant_event.guardian_participant_events.first
        unless guardian_participant_event
          Rails.logger.info("[Loops] notify_waiver_completion: no guardian_participant_event for participant_event #{participant_event.id}")
          return
        end

        return unless GuardianMailer.should_notify_waiver_completion?(guardian_participant_event: guardian_participant_event)

        GuardianMailer.waiver_completion(guardian_participant_event: guardian_participant_event).deliver_later
      end

      def notify_waiver_fully_signed(consent)
        participant_event = consent.participant_event
        return unless participant_event

        if participant_event.requires_guardian?
          # For minors, send to guardian
          guardian_participant_event = participant_event.guardian_participant_events.first
          unless guardian_participant_event
            Rails.logger.info("[Loops] notify_waiver_fully_signed: no guardian_participant_event for participant_event #{participant_event.id}")
            return
          end

          GuardianMailer.waiver_completion(guardian_participant_event: guardian_participant_event).deliver_later
          Rails.logger.info("Waiver fully signed notification sent to guardian for participant_event #{participant_event.id}")
        else
          # For adults, send to participant
          ParticipantMailer.adult_waiver_completion(participant_event: participant_event).deliver_later
          Rails.logger.info("Waiver fully signed notification sent to adult participant for participant_event #{participant_event.id}")
        end
      end

      def resend_guardian_portal_invitation(consent)
        participant_event = consent.participant_event
        return unless participant_event
        # Signing now happens mid-wizard (documents step) — don't invite
        # guardians before the participant has actually submitted.
        return if participant_event.code_of_conduct_accepted_at.blank?

        if participant_event.event.guardian_invites_locked?
          Rails.logger.info("[Waiver] resend_guardian_portal_invitation: guardian invites locked for event #{participant_event.event_id}, skipping for consent #{consent.id}")
          return
        end

        guardian_participant_event = consent.guardian_participant_event || participant_event.guardian_participant_events.first
        unless guardian_participant_event
          Rails.logger.info("[Waiver] resend_guardian_portal_invitation: no guardian_participant_event for consent #{consent.id}")
          return
        end

        if guardian_participant_event.completed_at.present?
          # Guardian already completed portal, send them direct waiver signing link
          GuardianMailer.waiver_signing(
            guardian_participant_event: guardian_participant_event,
            consent: consent
          ).deliver_later
          Rails.logger.info("Guardian waiver signing email sent for consent #{consent.id}")
        else
          # Guardian hasn't completed portal yet, resend portal invitation
          GuardianMailer.invitation(guardian_participant_event: guardian_participant_event).deliver_later
          Rails.logger.info("Guardian portal invitation resent for consent #{consent.id}")
        end
      end
    end
  end
end
