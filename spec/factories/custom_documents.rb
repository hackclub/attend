FactoryBot.define do
  factory :custom_document do
    event
    name { "Hotel Waiver" }
    docuseal_template_id { "1234" }
    signer_type { :participant }

    trait :guardian_only do
      signer_type { :guardian }
    end

    trait :dual_signer do
      signer_type { :participant_and_guardian }
    end

    trait :minors_only do
      signer_type { :minor_and_guardian }
    end

    trait :physical do
      document_kind { "physical" }
      docuseal_template_id { nil }

      transient do
        # Page count of the generated template PDF — caps how many photos of
        # the signed form can be uploaded.
        pages { 1 }
      end

      after(:build) do |doc, evaluator|
        pdf = Prawn::Document.new { |p| (evaluator.pages - 1).times { p.start_new_page } }
        doc.template_pdf.attach(
          io: StringIO.new(pdf.render),
          filename: "form.pdf",
          content_type: "application/pdf"
        )
      end
    end

    trait :archived do
      archived_at { Time.current }
    end

    trait :optional do
      optional { true }
    end
  end
end
