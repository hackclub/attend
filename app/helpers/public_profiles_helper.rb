module PublicProfilesHelper
  # Render-time guard for participant-stored URLs used as link hrefs: only
  # http(s) survives, everything else renders as no link. The model validates
  # this too — this is defense in depth at the point of output.
  def safe_external_url(value)
    uri = URI.parse(value.to_s)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # Social handles are stored bare (normalized on the model); URLs are built
  # here so a stored value can never point somewhere unexpected.
  def public_profile_social_links(participant)
    links = []
    if participant.public_profile_github.present?
      links << { label: "GitHub", icon: "github", url: "https://github.com/#{participant.public_profile_github}" }
    end
    if participant.public_profile_twitter.present?
      links << { label: "X (Twitter)", icon: "x", url: "https://x.com/#{participant.public_profile_twitter}" }
    end
    if participant.public_profile_linkedin.present?
      links << { label: "LinkedIn", icon: "linkedin", url: "https://www.linkedin.com/in/#{participant.public_profile_linkedin}" }
    end
    if (mastodon_url = safe_external_url(participant.public_profile_mastodon))
      links << { label: "Mastodon", icon: "mastodon", url: mastodon_url }
    end
    if participant.public_profile_bluesky.present?
      links << { label: "Bluesky", icon: "bluesky", url: "https://bsky.app/profile/#{participant.public_profile_bluesky}" }
    end
    links
  end
end
