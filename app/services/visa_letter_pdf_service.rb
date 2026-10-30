# Renders a visa invitation letter on the Hack Foundation's letterhead
# (HackFoundationLetter, Envoy's design): the template's body filled in from
# the application's frozen details, the template's signature or Zach's, and
# a footer repeating the applicant's name and birthday with the code
# embassies check at hack.club/visa-verify (which forwards to
# visas.hackclub.com/verify). Locked against editing, as Envoy's were.
class VisaLetterPdfService
  def initialize(application, template:)
    @application = application
    @template = template
  end

  def generate
    letter = HackFoundationLetter.new(
      title: "Visa invitation letter #{@application.reference_number}",
      microtext: "AUTHENTIC DOCUMENT • #{@application.full_name.upcase} • DOB: #{@application.date_of_birth.iso8601}",
      verification_code: @application.verification_code
    )
    letter.render(date: @application.letter_issued_on, signatory_name: @template.signatory_name,
      signatory_title: @template.signatory_title, signature: (@template.signature_image.download if @template.signature_image.attached?),
      lock: true) do |page|
      page.paragraphs(@template.render(@application))
    end
  end
end
