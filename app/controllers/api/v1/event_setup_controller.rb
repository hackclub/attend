module Api
  module V1
    # The tail of the setup wizard, for events that were created through the
    # API and so never passed through Admin::EventSetupController.
    #
    # The first three wizard steps already have API homes: basics, schedule and
    # the module toggles are all accepted by POST/PATCH on the Series API's
    # events endpoint. What was left with no programmatic equivalent is the
    # waiver step and the "finish setup" flip — an event whose setup is never
    # completed stays a draft — so those live here.
    #
    # Unlike event *creation*, none of this needs a series: the event already
    # exists, so an event API key reaches its own event's setup just as a
    # series key reaches every event in its series.
    class EventSetupController < BaseController
      include Pundit::Authorization
      include Api::V1::EventScoped
      include Api::V1::ApiAuditing

      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      def show
        render json: { setup: setup_json }
      end

      # Two ways to configure waivers, matching the web's radio buttons:
      #
      #   mode=auto    clone Hack Club's blueprint templates on DocuSeal and
      #                wire up the default field mappings — nothing else to do.
      #   mode=manual  point the event at DocuSeal templates you made yourself.
      #                Field mappings are *not* configured, so registration
      #                shouldn't open until they are (see the warning we return).
      def waivers
        case params[:mode].to_s
        when "auto" then configure_default_waivers
        when "manual" then configure_manual_waivers
        else
          render_error("mode must be either `auto` (clone the default templates) or `manual` (supply your own template ids)")
        end
      end

      # Mirrors Admin::EventSetupController#complete, including its one hard
      # precondition: without a support email there is no from/reply-to address
      # for a single participant or guardian email, so the event can't open.
      def complete
        if @event.support_email.blank?
          return render_error(
            "Set a support email (#{Event::SUPPORT_EMAIL_DOMAINS_SENTENCE}) before finishing setup — " \
            "it's the from and reply-to address on every participant and guardian email."
          )
        end

        unless @event.setup_complete?
          @event.update!(setup_completed_at: Time.current)
          audit_api_change!(:complete_setup, @event)
        end

        render json: { setup: setup_json }
      end

      private

      def authorize_event_access!
        authorize @event, :update?
      end

      def configure_default_waivers
        results = { "waiver" => Docuseal::DefaultTemplateSetup.new(@event).call("waiver") }
        if @event.freedom_waivers_enabled?
          results["freedom_waiver"] = Docuseal::DefaultTemplateSetup.new(@event).call("freedom_waiver")
        end

        created = results.select { |_, result| result.success? }.keys
        failures = results.reject { |_, result| result.success? }

        if failures.any?
          # 502, not 422: nothing the caller sent is wrong — DocuSeal refused
          # or was unreachable, and retrying the same request is the right move.
          return render json: {
            error: failures.map { |type, result| "#{type.humanize}: #{result.message}" }.join(" "),
            created: created,
            waivers: waivers_json
          }, status: :bad_gateway
        end

        audit_api_change!(:update_setup_waivers, @event, metadata: { mode: "auto", templates: created })
        render json: { created: created, waivers: waivers_json }
      end

      def configure_manual_waivers
        attributes = manual_waiver_params
        if attributes.empty?
          return render_error("Supply docuseal_waiver_template_id and/or docuseal_freedom_waiver_template_id, or use mode=auto")
        end

        if @event.update(attributes)
          audit_api_change!(:update_setup_waivers, @event, metadata: { mode: "manual" })
          render json: {
            waivers: waivers_json,
            warning: "Field mappings are not configured for templates you supply yourself. " \
                     "Set them from the event's integrations page before opening registration."
          }
        else
          render_error(@event.errors.full_messages.to_sentence)
        end
      end

      # Only the keys actually sent are written, so setting one template id
      # never clears the other. An explicit empty string does clear one, which
      # is how a client detaches a template it no longer wants.
      def manual_waiver_params
        params.permit(:docuseal_waiver_template_id, :docuseal_freedom_waiver_template_id)
          .to_h
          .symbolize_keys
          .transform_values(&:presence)
      end

      # The same questions the wizard asks when it decides which step to resume
      # on, answered for a client that has no wizard to resume.
      def setup_json
        steps = {
          basics: @event.name.present? && @event.support_email.present?,
          schedule: @event.starts_at.present? && @event.ends_at.present?,
          waivers: @event.docuseal_waiver_template_id.present?,
          team: @event.event_role_assignments.exists?
        }

        {
          complete: @event.setup_complete?,
          completed_at: @event.setup_completed_at&.iso8601,
          steps: steps,
          remaining: steps.reject { |_, done| done }.keys,
          waivers: waivers_json
        }
      end

      def waivers_json
        {
          docuseal_waiver_template_id: @event.docuseal_waiver_template_id,
          docuseal_freedom_waiver_template_id: @event.docuseal_freedom_waiver_template_id,
          freedom_waivers_enabled: @event.freedom_waivers_enabled?
        }
      end
    end
  end
end
