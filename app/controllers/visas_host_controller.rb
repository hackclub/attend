# visas.hackclub.com, Envoy's old domain (see VisaLetter and config/routes.rb).
# Embassies check letters here, and Envoy's emails link to letters here, so
# this answers strangers who have never signed in to Attend. Every other
# Envoy page is redirected to where it lives in Attend now.
#
# Not an ApplicationController subclass, for the reasons
# BadgeRedirectsController gives: nothing about a signed-in person using
# Attend belongs between an embassy and a letter. Forgery protection stays on:
# /verify takes a form post, and nothing else on this host takes any write.
class VisasHostController < ActionController::Base
  layout "visas_host"

  rate_limit to: 30, within: 15.minutes, only: :verify, with: -> {
    flash.now[:alert] = "Too many attempts. Please wait a few minutes and try again."
    render :verify_form, status: :too_many_requests
  }
  rate_limit to: 20, within: 15.minutes, only: :download_letter, with: -> {
    @problem = "Too many attempts. Please wait a few minutes and try again."
    render :invalid_link, status: :too_many_requests
  }

  # Envoy's form. The link printed on a letter fills the code in; checking it
  # is still a button press, as it was in Envoy.
  def verify_form
    @verification_code = params[:code]
  end

  # Reads only what the letter printed (the frozen letter_* columns), so a
  # letter checks out as it was issued even if the event changed since. Only
  # a sent letter is confirmed; any other status gets the same pending page,
  # so a code says nothing about how an application was reviewed.
  def verify
    @verification_code = params[:code].to_s.gsub(/\s+/, "").upcase
    @application = VisaLetterApplication.find_by(verification_code: @verification_code) if @verification_code.present?

    if @application&.letter_sent?
      render :verified
    elsif @application
      render :pending
    else
      flash.now[:alert] = "Invalid verification code. Please check and try again."
      render :verify_form, status: :unprocessable_content
    end
  end

  # The download link in Envoy's letter-ready emails. Its token is the
  # letter's verification code.
  def download_letter
    application = VisaLetterApplication.find_by(id: params[:id])
    token = params[:token].to_s
    unless application && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, application.verification_code) &&
        application.letter_sent? && application.letter_pdf.attached?
      @problem = "Invalid or expired download link."
      render :invalid_link, status: :not_found
      return
    end

    send_data application.letter_pdf.download, filename: application.letter_pdf.filename.to_s,
      type: "application/pdf", disposition: "attachment"
  end

  # An application's page in Envoy's emails. Attend's needs the applicant to
  # sign in, and Envoy's applications move to the account with their email.
  def show_application
    redirect_to_attend visas_application_path(params[:id])
  end

  # An event's page and form, and the links in Envoy's invitation and
  # rejection emails. The import records each event's Envoy slug, and an
  # invitation's token carries over. Temporary, since the answer depends on
  # what's been imported or mapped: a browser keeps a 301 for good.
  def event_page
    event = Event.find_by("config->>'legacy_envoy_slug' = ?", params[:slug])
    return redirect_to_attend(visas_path, status: :found) if event.nil?

    redirect_to_attend visas_apply_path(event.slug, invite: params[:invitation].presence), status: :found
  end

  def lookup
    redirect_to_attend visas_path
  end

  def documentation
    redirect_to_attend visas_faq_path
  end

  # Envoy's admin emails linked here. Attend checks who may see it.
  # Temporary too: an application missing now may be imported later.
  def admin_application
    application = VisaLetterApplication.find_by(id: params[:id])
    return redirect_to_attend(admin_root_path, status: :found) if application.nil?

    redirect_to_attend admin_event_visa_letter_path(application.event, application), status: :found
  end

  def admin
    redirect_to_attend admin_root_path
  end

  # The catch-all route hands this every verb. A GET is sent to Attend's visa
  # pages; anything that tries to write is refused by forgery protection
  # before it gets here.
  def elsewhere
    redirect_to_attend visas_path
  end

  private

  def redirect_to_attend(path, status: :moved_permanently)
    redirect_to AttendUrls.attend_url(path), allow_other_host: true, status: status
  end
end
