require "rails_helper"

RSpec.describe GenerateVisaLetterJob do
  let(:application) { create(:visa_letter_application) }

  before { create(:visa_letter_template, :default) }

  it "issues an approved application's letter and emails it" do
    application.approve!(by: create(:user))

    expect { described_class.perform_now(application) }.to have_enqueued_mail(VisaLetterMailer, :letter_ready)
    expect(application.reload).to be_letter_sent
    expect(application.letter_pdf).to be_attached
  end

  it "leaves an application that isn't waiting for its letter alone" do
    expect { described_class.perform_now(application) }.not_to have_enqueued_mail(VisaLetterMailer, :letter_ready)
    expect(application.reload).to be_pending
  end
end
