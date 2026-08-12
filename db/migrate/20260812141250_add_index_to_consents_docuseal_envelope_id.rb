class AddIndexToConsentsDocusealEnvelopeId < ActiveRecord::Migration[8.1]
  def change
    # Every DocuSeal webhook without consent metadata looks a consent up by
    # envelope id; without this index that's a sequential scan (100-400ms in
    # production traces).
    add_index :consents, :docuseal_envelope_id
  end
end
