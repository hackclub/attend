class MoveDocusealHostToSignaturesDomain < ActiveRecord::Migration[8.1]
  OLD_HOST = "sign.b.selfhosted.hackclub.com".freeze
  NEW_HOST = "signatures.hackclub.com".freeze

  # The self-hosted DocuSeal box moved domains. Records pin the *host* they
  # were created on, and HostConfig#for_host matches that value against the
  # configured clusters — once credentials point at the new domain, any row
  # still holding the old one falls through to legacy DocuSeal Cloud creds
  # and every API call 403s. Same box, same data, so rewriting the host is
  # safe: slugs and submission ids are unchanged.
  #
  # Some rows stored the host with a scheme ("https://sign.b..."), which the
  # embed views interpolate straight into a script src and produce
  # "https://https://...". Both variants are normalised to the bare host.
  def up
    rewrite_host(OLD_HOST, NEW_HOST)
  end

  def down
    rewrite_host(NEW_HOST, OLD_HOST)
  end

  private

  def rewrite_host(from, to)
    [ from, "https://#{from}" ].each do |stored|
      say_with_time("Rewriting docuseal_host #{stored} -> #{to}") do
        Event.where(docuseal_host: stored).update_all(docuseal_host: to) +
          Consent.where(docuseal_host: stored).update_all(docuseal_host: to)
      end
    end
  end
end
