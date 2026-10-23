module Api
  # GDPR endpoints called by the Hack Club privacy hub (https://yeet.hackclub.com).
  # Authenticated by the hub's signed token; acts on the token claims only,
  # never on the request body. See app/services/privacy/README.md.
  class PrivacyController < ActionController::API
    before_action :authenticate!

    rescue_from Privacy::Eraser::ManualReviewRequired do |e|
      log("manual_review_required reason=#{e.reason}")
      render json: { error: "manual_review_required", reason: e.reason }, status: :conflict
    end

    # the hub retries a 503, with a fresh token
    rescue_from Privacy::Eraser::Unavailable do |e|
      log(e.code)
      render json: { error: e.code }, status: :service_unavailable
    end

    def delete
      respond(Privacy::Eraser.new(@claims.subject).call(dry_run: @claims.dry_run))
    end

    # export delivery is not specified yet, so this reports what a deletion
    # would remove without changing anything
    def export
      respond(Privacy::Eraser.new(@claims.subject).call(dry_run: true, review: false))
    end

    private

    def authenticate!
      token = request.authorization.to_s[/\ABearer (.+)\z/, 1]
      @claims = Privacy::Token.verify!(token)
      return render(json: { error: "action_mismatch" }, status: :bad_request) unless @claims.action == action_name

      # the hub mints a new jti for every attempt, so a repeat is a replay
      render json: { error: "replayed" }, status: :conflict unless Privacy::Token.first_use!(@claims.jti)
    rescue Privacy::Token::Invalid => e
      status = e.code == "jwks_unavailable" ? :service_unavailable : :unauthorized
      render json: { error: e.code }, status:
    end

    def respond(result)
      log("found=#{result.found}")
      render json: {
        request_id: @claims.request_id,
        found: result.found,
        dry_run: @claims.dry_run,
        deleted: result.deleted,
        retained: result.retained
      }
    end

    # request_id and the outcome only: never the token, the subject's
    # identifiers, or anything that was deleted
    def log(outcome)
      Rails.logger.info("[Privacy] #{action_name} request_id=#{@claims.request_id} dry_run=#{@claims.dry_run} #{outcome}")
    end
  end
end
