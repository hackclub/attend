namespace :consent_documents do
  desc <<~DESC
    Store every signed document for DocuSeal consents signed before
    `consents.documents` existed.

    The submission.completed webhook used to keep only the first entry of its
    `documents` array in document_url, so a template with several documents
    only ever linked the first. This fetches the full list from
    GET /submissions/:id/documents. Admins opening a document refresh that one
    consent anyway; this fills in the rest so every link shows up front.

    ENV:
      EVENT=<slug>   only this event (default: every event)
      APPLY=1        actually write (default: dry run)
  DESC
  task backfill: :environment do
    apply = ENV["APPLY"] == "1"

    scope = Consent.signed
      .where.not(docuseal_envelope_id: nil)
      .where("consents.documents = '[]'::jsonb")
    scope = scope.joins(:participant_event).where(participant_events: { event_id: Event.find_by!(slug: ENV.fetch("EVENT")).id }) if ENV["EVENT"].present?

    puts "#{scope.count} consent#{'s' unless scope.count == 1} to backfill (apply=#{apply})"

    scope.find_each do |consent|
      unless apply
        puts "  would fetch #{consent.id} (submission #{consent.docuseal_envelope_id})"
        next
      end

      consent.refresh_documents_from_docuseal!
      stored = consent.reload.documents.size
      puts "  #{consent.id}: #{stored.zero? ? 'DocuSeal returned nothing, left as is' : "#{stored} document#{'s' unless stored == 1}"}"
    end
  end
end
