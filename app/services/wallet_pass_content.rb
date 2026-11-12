# Tracks whether what's on an Apple Wallet pass actually changed.
#
# Each pass stores a fingerprint of its pass.json plus the artwork rendered
# into it, and content_updated_at, the moment that fingerprint last changed.
# That timestamp is what Wallet sees as the pass's last-modified (see
# PasskitPassExtensions), so devices are only told to refetch, and only sent
# a fresh pass, when something on it really differs.
class WalletPassContent
  class << self
    def digest(pass)
      generator = Passkit::Generator.new(pass)
      json = I18n.with_locale(pass.language) { generator.pass_json }
      artwork = pass.instance.respond_to?(:artwork_checksums) ? pass.instance.artwork_checksums : []

      Digest::SHA256.hexdigest(JSON.generate([ json, artwork ]))
    end

    # Records the pass's current fingerprint and returns whether its contents
    # changed since the last one.
    #
    # A pass fingerprinted for the first time has nothing to compare against.
    # `unknown:` says how to treat it: WalletPassUpdateService runs because
    # something may have changed, so it passes :changed (push, as before);
    # a device fetch passes :unchanged, keeping the pass's existing
    # last-modified so devices that already hold it aren't sent it again.
    def refresh!(pass, unknown: :changed)
      digest = digest(pass)
      return false if pass.content_digest == digest

      changed = pass.content_digest.present? || unknown == :changed
      pass.update_columns(
        content_digest: digest,
        content_updated_at: changed ? Time.current : pass.last_update
      )
      changed
    end
  end
end
