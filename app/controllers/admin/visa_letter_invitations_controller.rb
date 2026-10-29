module Admin
  # Inviting people to ask for a visa letter, for events whose letters are
  # invite-only or whose form has closed. An invitation also lets someone
  # whose request was hard-rejected apply again. Same reviewers as the
  # applications themselves.
  class VisaLetterInvitationsController < BaseController
    before_action :set_event
    before_action :require_event_selected
    before_action { authorize @event, :review_visa_letters? }

    def index
      @invitations = @event.visa_letter_invitations.includes(:issued_by, :visa_letter_application).order(created_at: :desc)
    end

    # One address per line, or separated by commas. Someone already invited
    # and yet to apply gets the same invitation again rather than a new one.
    def create
      emails = params[:emails].to_s.split(/[\s,;]+/).map { |email| email.strip.downcase }.compact_blank.uniq
      sent = []
      skipped = []

      emails.each do |email|
        invitation = @event.visa_letter_invitations.unclaimed.for_email(email).first ||
          @event.visa_letter_invitations.new(email: email, issued_by: current_user)
        if invitation.save
          sent << invitation
        else
          skipped << "#{email} (#{invitation.errors.full_messages.to_sentence.downcase})"
        end
      end

      sent.each { |invitation| VisaLetterMailer.invitation_to_apply(invitation: invitation).deliver_later }
      @record = sent.first

      notice = if sent.one?
        "Invitation sent to #{sent.first.email} for #{@event.name}."
      elsif sent.any?
        "Invitations sent to #{helpers.pluralize(sent.size, "person", plural: "people")} for #{@event.name}."
      end
      alert = skipped.any? ? "Not invited: #{skipped.to_sentence}." : (emails.empty? ? "Add at least one email address." : nil)
      redirect_to admin_event_visa_letter_invitations_path(@event), notice: notice, alert: alert
    end

    def destroy
      @record = invitation = @event.visa_letter_invitations.find(params[:id])
      if invitation.claimed?
        redirect_to admin_event_visa_letter_invitations_path(@event), alert: "#{invitation.email} has already used this invitation."
        return
      end

      invitation.destroy!
      redirect_to admin_event_visa_letter_invitations_path(@event), notice: "Invitation for #{invitation.email} withdrawn."
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end
  end
end
