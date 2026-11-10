require "rails_helper"

RSpec.describe PurgeUnattachedBlobsJob do
  def blob(created_at:)
    ActiveStorage::Blob.create_and_upload!(io: Rails.root.join("spec/fixtures/files/headshot.png").open, filename: "photo.png", content_type: "image/png")
      .tap { |b| b.update_columns(created_at: created_at) }
  end

  it "purges blobs nothing attached once the grace period is over" do
    abandoned = blob(created_at: 3.days.ago)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(abandoned.id)).to be(false)
    expect(ActiveStorage::Blob.service.exist?(abandoned.key)).to be(false)
  end

  it "leaves a recent upload that could still be attached" do
    recent = blob(created_at: 1.day.ago)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(recent.id)).to be(true)
  end

  it "leaves attached blobs alone however old they are" do
    participant = create(:participant)
    old = blob(created_at: 1.year.ago)
    participant.headshot.attach(old)

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(old.id)).to be(true)
    expect(participant.reload.headshot).to be_attached
  end

  it "keeps going when one blob can't be purged" do
    stuck = blob(created_at: 3.days.ago)
    abandoned = blob(created_at: 3.days.ago)
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_wrap_original do |original|
      raise "storage unavailable" if original.receiver.id == stuck.id

      original.call
    end

    described_class.perform_now

    expect(ActiveStorage::Blob.exists?(stuck.id)).to be(true)
    expect(ActiveStorage::Blob.exists?(abandoned.id)).to be(false)
  end
end
