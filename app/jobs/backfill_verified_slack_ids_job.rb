# Fills users.verified_slack_id from the encrypted oidc_claims. Enqueued by the
# migration that adds the column, so it runs without anyone shelling into a pod,
# and safe to rerun (`rails backfill:verified_slack_ids`): rows already in step
# are skipped without a write. Every save also resyncs the column (see
# User#sync_verified_slack_id), so anything this misses heals on next sign-in.
class BackfillVerifiedSlackIdsJob < ApplicationJob
  queue_as :default

  def perform
    repaired = 0
    failed = 0

    User.where.not(oidc_claims: nil).find_each do |user|
      slack_id = User.verified_slack_id_from(user.oidc_claims)
      next if user.verified_slack_id == slack_id

      user.update_column(:verified_slack_id, slack_id)
      repaired += 1
    rescue StandardError => e
      # One bad row (undecryptable claims, odd data) must not stop the rest.
      failed += 1
      Rails.logger.warn("[BackfillVerifiedSlackIdsJob] Skipped user #{user.id}: #{e.class}: #{e.message}")
    end

    Rails.logger.info("[BackfillVerifiedSlackIdsJob] Repaired #{repaired}, failed #{failed}")
    { repaired: repaired, failed: failed }
  end
end
