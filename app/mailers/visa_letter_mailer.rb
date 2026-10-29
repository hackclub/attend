# Emails to visa letter applicants. Sent from the event's support address,
# like the other participant mail, so replies reach the event team.
class VisaLetterMailer < ApplicationMailer
  # The letter itself, attached: someone applying for a visa needs the PDF,
  # not a link into an account they may never have used.
  def letter_ready(application:)
    setup(application)
    attachments[application.letter_pdf.filename.to_s] = {
      mime_type: "application/pdf",
      content: application.letter_pdf.download
    }

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "Your visa invitation letter for #{@event.name}")
  end

  def rejected(application:)
    setup(application)
    @reason = application.rejection_reason
    @can_reapply = application.soft_rejected?

    mail(to: application.email, from: @from, reply_to: @support_email,
      subject: "Your visa invitation letter request for #{@event.name}")
  end

  private

  def setup(application)
    @application = application
    @event = application.event
    @emailable = application
    @first_name = application.full_name.to_s.split.first || "there"
    @support_email = @event.effective_support_email
    @from = "Hack Club #{@event.name} <#{@support_email}>"
  end
end
