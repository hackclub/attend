require "rails_helper"

RSpec.describe "Api::V1::Webhooks", type: :request do
  describe "POST /api/v1/webhooks/docuseal" do
    let(:webhook_secret) { "test_webhook_secret" }
    let(:event) { create(:event) }
    let(:participant) { create(:participant) }
    let(:participant_event) { create(:participant_event, event: event, participant: participant) }
    let!(:consent) do
      create(:consent,
        participant_event: participant_event,
        consent_type: :waiver,
        status: :sent,
        docuseal_envelope_id: "12345"
      )
    end

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("DOCUSEAL_WEBHOOK_SECRET").and_return(webhook_secret)
    end

    context "with valid webhook secret" do
      let(:headers) { { "X-Webhook-Secret" => webhook_secret, "Content-Type" => "application/json" } }

      it "handles submission.completed event" do
        payload = {
          "event_type" => "submission.completed",
          "data" => {
            "id" => "12345",
            "metadata" => { "consent_id" => consent.id.to_s },
            "documents" => [ { "url" => "https://example.com/doc.pdf" } ]
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.status).to eq("signed")
        expect(consent.document_url).to eq("https://example.com/doc.pdf")
      end

      it "keeps every document of a multi-document submission" do
        payload = {
          "event_type" => "submission.completed",
          "data" => {
            "id" => "12345",
            "metadata" => { "consent_id" => consent.id.to_s },
            "documents" => [
              { "name" => "Waiver", "url" => "https://example.com/waiver.pdf" },
              { "name" => "Photo Release", "url" => "https://example.com/photo.pdf" }
            ]
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        consent.reload
        expect(consent.documents).to eq([
          { "name" => "Waiver", "url" => "https://example.com/waiver.pdf" },
          { "name" => "Photo Release", "url" => "https://example.com/photo.pdf" }
        ])
        expect(consent.document_url).to eq("https://example.com/waiver.pdf")
      end

      it "handles form.completed event for participant (teen signs first)" do
        consent.update!(pending_on: "participant")

        payload = {
          "event_type" => "form.completed",
          "data" => {
            "id" => "12345",
            "role" => "Participant",
            "metadata" => { "consent_id" => consent.id.to_s }
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.participant_signed_at).to be_present
        expect(consent.pending_on).to eq("guardian")
      end

      it "handles form.completed event for guardian (guardian signs second)" do
        consent.update!(pending_on: "guardian", participant_signed_at: Time.current)

        payload = {
          "event_type" => "form.completed",
          "data" => {
            "id" => "12345",
            "role" => "Guardian",
            "metadata" => { "consent_id" => consent.id.to_s }
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.guardian_signed_at).to be_present
        expect(consent.pending_on).to be_nil
      end

      context "with freedom waiver consent" do
        let!(:freedom_consent) do
          create(:consent,
            participant_event: participant_event,
            consent_type: :freedom_waiver,
            status: :sent,
            docuseal_envelope_id: "67890"
          )
        end

        it "sets freedom_waiver_granted to true when granted checkbox is checked" do
          payload = {
            "event_type" => "form.completed",
            "data" => {
              "id" => "67890",
              "role" => "Parent/Legal Guardian",
              "metadata" => { "consent_id" => freedom_consent.id.to_s },
              "values" => [
                { "field" => "Freedom Waiver Granted", "value" => true },
                { "field" => "Freedom Waiver Rejected", "value" => false }
              ]
            }
          }

          post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          participant_event.reload
          expect(participant_event.safeguarding_info).to be_present
          expect(participant_event.safeguarding_info.freedom_waiver_granted).to be true
        end

        it "sets freedom_waiver_granted to false when rejected checkbox is checked" do
          payload = {
            "event_type" => "form.completed",
            "data" => {
              "id" => "67890",
              "role" => "Parent/Legal Guardian",
              "metadata" => { "consent_id" => freedom_consent.id.to_s },
              "values" => [
                { "field" => "Freedom Waiver Granted", "value" => false },
                { "field" => "Freedom Waiver Rejected", "value" => true }
              ]
            }
          }

          post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          participant_event.reload
          expect(participant_event.safeguarding_info).to be_present
          expect(participant_event.safeguarding_info.freedom_waiver_granted).to be false
        end

        it "handles case-insensitive field name matching" do
          payload = {
            "event_type" => "form.completed",
            "data" => {
              "id" => "67890",
              "role" => "Parent/Legal Guardian",
              "metadata" => { "consent_id" => freedom_consent.id.to_s },
              "values" => [
                { "field" => "freedom waiver GRANTED", "value" => true },
                { "field" => "freedom waiver REJECTED", "value" => false }
              ]
            }
          }

          post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          participant_event.reload
          expect(participant_event.safeguarding_info.freedom_waiver_granted).to be true
        end

        it "handles string truthy values like 'Yes' and 'Checked'" do
          %w[Yes yes checked Checked on true 1].each do |truthy_val|
            payload = {
              "event_type" => "form.completed",
              "data" => {
                "id" => "67890",
                "role" => "Parent/Legal Guardian",
                "metadata" => { "consent_id" => freedom_consent.id.to_s },
                "values" => [
                  { "field" => "Freedom Waiver Granted", "value" => truthy_val },
                  { "field" => "Freedom Waiver Rejected", "value" => false }
                ]
              }
            }

            post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

            expect(response).to have_http_status(:ok)
            participant_event.reload
            expect(participant_event.safeguarding_info.freedom_waiver_granted).to be(true),
              "Expected freedom_waiver_granted to be true for value #{truthy_val.inspect}"
          end
        end
      end

      it "handles form.declined event" do
        payload = {
          "event_type" => "form.declined",
          "data" => {
            "id" => "12345",
            "role" => "Guardian",
            "metadata" => { "consent_id" => consent.id.to_s }
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.status).to eq("failed")
        expect(consent.failure_reason).to eq("declined_by_guardian")
      end

      it "finds consent by docuseal_envelope_id when metadata missing" do
        payload = {
          "event_type" => "submission.completed",
          "data" => {
            "id" => "12345",
            "documents" => [ { "url" => "https://example.com/doc.pdf" } ]
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.status).to eq("signed")
      end

      # A re-issued waiver reuses the same consent row, so the old submission's
      # metadata still points at it. Late events from that old submission must
      # not land on the fresh waiver.
      context "when the event comes from a submission the consent no longer points at" do
        let(:old_submission_completed) do
          {
            "event_type" => "submission.completed",
            "data" => {
              "id" => 111,
              "metadata" => { "consent_id" => consent.id.to_s },
              "documents" => [ { "url" => "https://example.com/old.pdf" } ]
            }
          }
        end

        it "ignores submission.completed when the consent has moved on to a newer submission" do
          consent.update!(docuseal_envelope_id: "222")

          post docuseal_api_v1_webhooks_path, params: old_submission_completed.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          consent.reload
          expect(consent.status).to eq("sent")
          expect(consent.signed_at).to be_nil
          expect(consent.document_url).to be_nil
        end

        it "ignores submission.completed when the consent was just reset and has no submission yet" do
          consent.update!(status: :pending, docuseal_envelope_id: nil)

          post docuseal_api_v1_webhooks_path, params: old_submission_completed.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          consent.reload
          expect(consent.status).to eq("pending")
          expect(consent.signed_at).to be_nil
        end

        it "ignores form.completed whose submission_id is not the current one" do
          consent.update!(docuseal_envelope_id: "222", pending_on: "participant")

          payload = {
            "event_type" => "form.completed",
            "data" => {
              "id" => 999,
              "submission_id" => 111,
              "role" => "Participant",
              "metadata" => { "consent_id" => consent.id.to_s }
            }
          }

          post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          consent.reload
          expect(consent.participant_signed_at).to be_nil
          expect(consent.pending_on).to eq("participant")
        end

        it "ignores a stale guardian form.completed on a freedom waiver" do
          freedom_consent = create(:consent,
            participant_event: participant_event,
            consent_type: :freedom_waiver,
            status: :pending,
            docuseal_envelope_id: nil
          )

          payload = {
            "event_type" => "form.completed",
            "data" => {
              "id" => 999,
              "submission" => { "id" => 111 },
              "role" => "Parent/Legal Guardian",
              "metadata" => { "consent_id" => freedom_consent.id.to_s },
              "values" => [ { "field" => "Freedom Waiver Granted", "value" => true } ]
            }
          }

          post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
          expect(freedom_consent.reload.guardian_signed_at).to be_nil
          expect(participant_event.reload.safeguarding_info&.freedom_waiver_granted).to be_falsey
        end
      end

      it "applies submission.completed when the integer submission id matches the consent's envelope" do
        payload = {
          "event_type" => "submission.completed",
          "data" => {
            "id" => 12345,
            "metadata" => { "consent_id" => consent.id.to_s },
            "documents" => [ { "url" => "https://example.com/doc.pdf" } ]
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        expect(consent.reload.status).to eq("signed")
      end

      it "applies form.completed when its submission_id matches, even though the submitter id differs" do
        consent.update!(pending_on: "participant")

        payload = {
          "event_type" => "form.completed",
          "data" => {
            "id" => 999,
            "submission_id" => 12345,
            "role" => "Participant",
            "metadata" => { "consent_id" => consent.id.to_s }
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        consent.reload
        expect(consent.participant_signed_at).to be_present
        expect(consent.pending_on).to eq("guardian")
      end
    end

    context "with invalid webhook secret" do
      it "returns unauthorized" do
        headers = { "X-Webhook-Secret" => "wrong_secret", "Content-Type" => "application/json" }
        payload = { "event_type" => "submission.completed", "data" => {} }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with missing webhook secret header" do
      it "returns unauthorized" do
        headers = { "Content-Type" => "application/json" }
        payload = { "event_type" => "submission.completed", "data" => {} }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when webhook secret is not configured" do
      before do
        allow(ENV).to receive(:[]).with("DOCUSEAL_WEBHOOK_SECRET").and_return(nil)
        allow(Rails.application.credentials).to receive(:dig).with(:docuseal, :webhook_secret).and_return(nil)
      end

      it "rejects the webhook with service unavailable" do
        headers = { "Content-Type" => "application/json" }
        payload = {
          "event_type" => "submission.completed",
          "data" => {
            "id" => "12345",
            "metadata" => { "consent_id" => consent.id.to_s },
            "documents" => []
          }
        }

        post docuseal_api_v1_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:service_unavailable)
      end
    end
  end
end
