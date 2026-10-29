# Issues an approved application's visa letter and emails it. Queued once the
# approval has committed. An application that has moved on since (the letter
# already went, say, from a retry) is left alone. With no template to use,
# issue_letter! raises, so the failure shows up rather than the applicant
# waiting on a letter that never comes.
class GenerateVisaLetterJob < ApplicationJob
  queue_as :default

  def perform(application)
    return unless application.approved?

    application.issue_letter!
    VisaLetterMailer.letter_ready(application: application).deliver_later
  end
end
