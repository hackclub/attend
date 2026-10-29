# Emails about visa invitation letters. Applicants hear from the event's
# support address, like the other participant mail, so replies reach the
# event team.
class VisaLetterMailer < ApplicationMailer
  # Confirms what they sent and where to follow it up.
  def received(application:)
    setup(application)
    @application_url = visas_application_url(application)

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "Your Visa Letter Application Has Been Submitted - #{@event.name}")
  end

  # The letter itself, attached: someone applying for a visa needs the PDF,
  # not a link into an account they may never have used.
  def letter_ready(application:)
    setup(application)
    @download_url = visas_application_letter_url(application)
    attachments[application.letter_pdf.filename.to_s] = {
      mime_type: "application/pdf",
      content: application.letter_pdf.download
    }

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "Your Visa Letter is Ready - #{@event.name}")
  end

  def rejected(application:)
    setup(application)
    @reason = application.rejection_reason
    @can_reapply = application.soft_rejected?
    @apply_url = visas_apply_url(@event.slug)

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "Update on Your Visa Letter Application - #{@event.name}")
  end

  # A hard rejection softened by staff: they can apply again after all.
  def rejection_downgraded(application:)
    setup(application)
    @apply_url = visas_apply_url(@event.slug)

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "You Can Now Reapply for Your Visa Letter - #{@event.name}")
  end

  def invitation_to_apply(invitation:)
    @event = invitation.event
    @location = event_location(@event)
    @emailable = invitation
    @support_email = @event.effective_support_email
    @apply_url = visas_apply_url(@event.slug, invite: invitation.token)

    mail(to: invitation.email, from: "Hack Club #{@event.name} <#{@support_email}>", reply_to: @support_email,
      subject: "You're Invited to Apply for a Visa Letter - #{@event.name}")
  end

  # To the event's admins, who review applications. An event without any
  # goes to its support address, so a request is never sent nowhere.
  def new_application(application:)
    @application = application
    @event = application.event
    @emailable = application
    @review_url = admin_event_visa_letter_url(@event, application)
    recipients = User.joins(:event_role_assignments)
      .where(event_role_assignments: { event_id: @event.id, role: "event_admin" }).distinct.pluck(:email)

    mail(to: recipients.presence || @event.effective_support_email,
      subject: "New Visa Letter Application - #{@event.name}")
  end

  private

  def event_location(event)
    [ event.venue_name, event.location_address, event.location_city, event.location_country ].compact_blank.uniq.join(", ")
  end

  def setup(application)
    @application = application
    @event = application.event
    @emailable = application
    @location = event_location(@event)
    @support_email = @event.effective_support_email
    @from = "Hack Club #{@event.name} <#{@support_email}>"
  end
end
