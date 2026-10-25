class SlackService
  SLACK_API_BASE = "https://slack.com/api"

  class Error < StandardError; end

  # Slack refused the call for going over the method's rate limit; wait
  # retry_after seconds before trying again.
  class RateLimited < Error
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Slack API rate limited (retry after #{retry_after}s)")
    end
  end

  # The account belongs to the Enterprise org but not to the workspace the
  # channel is in, so it can't be invited until someone adds it there.
  class NotInWorkspace < Error; end

  # The call never reached Slack, or came back unreadable: a timeout, a reset
  # connection, a proxy error page. Nothing to fix by hand, so callers that
  # can retry should, rather than treating it like a refusal from Slack.
  class TransportError < Error; end

  def initialize(bot_token: nil)
    @bot_token = bot_token || Rails.application.credentials.dig(:slack, :bot_token)
  end

  def invite_to_channel(channel_id:, user_id:)
    response = post("conversations.invite", channel: channel_id, users: user_id)

    if response["ok"]
      { success: true }
    elsif response["error"] == "already_in_channel"
      { success: true, already_member: true }
    elsif response["error"] == "org_user_not_in_team"
      raise NotInWorkspace, "Failed to invite user to channel: #{response["error"]}"
    else
      raise Error, "Failed to invite user to channel: #{response["error"]}"
    end
  end

  # Needs the bot in the channel and the channels:manage (public) or
  # groups:write (private) scope. Slack also answers not_in_channel when the
  # bot itself isn't in the channel, so callers can't take not_member as proof
  # the user is gone unless they know the bot is there.
  def remove_from_channel(channel_id:, user_id:)
    response = post("conversations.kick", channel: channel_id, user: user_id)

    if response["ok"]
      { success: true }
    elsif response["error"] == "not_in_channel"
      { success: true, not_member: true }
    else
      raise Error, "Failed to remove user from channel: #{response["error"]}"
    end
  end

  def get_user_info(user_id:)
    response = post("users.info", user: user_id)

    if response["ok"]
      response["user"]
    else
      raise Error, "Failed to get user info: #{response["error"]}"
    end
  end

  def send_dm(user_id:, text:)
    conversation = open_conversation(user_id: user_id)
    channel_id = conversation["channel"]["id"]

    response = post("chat.postMessage", channel: channel_id, text: text)

    if response["ok"]
      { success: true, ts: response["ts"] }
    else
      raise Error, "Failed to send DM: #{response["error"]}"
    end
  end

  def send_dm_with_blocks(user_id:, text:, blocks:)
    conversation = open_conversation(user_id: user_id)
    channel_id = conversation["channel"]["id"]

    response = post("chat.postMessage", channel: channel_id, text: text, blocks: blocks)

    if response["ok"]
      { success: true, ts: response["ts"] }
    else
      raise Error, "Failed to send DM: #{response["error"]}"
    end
  end

  def send_to_channel(channel_id:, text:, blocks: nil, thread_ts: nil)
    params = { channel: channel_id, text: text }
    params[:blocks] = blocks if blocks
    params[:thread_ts] = thread_ts if thread_ts

    response = post("chat.postMessage", params)

    if response["ok"]
      { success: true, ts: response["ts"] }
    else
      raise Error, "Failed to send message to channel: #{response["error"]}"
    end
  end

  def update_channel_message(channel_id:, ts:, text:, blocks: nil)
    params = { channel: channel_id, ts: ts, text: text }
    params[:blocks] = blocks if blocks

    response = post("chat.update", params)

    if response["ok"]
      { success: true, ts: response["ts"] }
    else
      raise Error, "Failed to update message: #{response["error"]}"
    end
  end

  def open_conversation(user_id:)
    response = post("conversations.open", users: user_id)

    if response["ok"]
      response
    else
      raise Error, "Failed to open conversation: #{response["error"]}"
    end
  end

  def exchange_code_for_token(code:, redirect_uri:)
    client_id = Rails.application.credentials.dig(:slack, :client_id)
    client_secret = Rails.application.credentials.dig(:slack, :client_secret)

    response = Faraday.post("#{SLACK_API_BASE}/oauth.v2.access") do |req|
      req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = URI.encode_www_form(
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: redirect_uri
      )
    end

    parsed = JSON.parse(response.body)

    if parsed["ok"]
      {
        slack_user_id: parsed.dig("authed_user", "id"),
        team_id: parsed["team"]["id"],
        team_name: parsed["team"]["name"]
      }
    else
      raise Error, "Failed to exchange code for token: #{parsed["error"]}"
    end
  rescue Faraday::Error, JSON::ParserError => e
    raise Error, "Slack API error: #{e.message}"
  end

  def authorization_url(participant_event_id:, redirect_uri:)
    client_id = Rails.application.credentials.dig(:slack, :client_id)
    state = generate_state(participant_event_id)

    params = {
      client_id: client_id,
      scope: "",
      user_scope: "identity.basic",
      redirect_uri: redirect_uri,
      state: state
    }

    "https://slack.com/oauth/v2/authorize?#{params.to_query}"
  end

  def generate_state(participant_event_id)
    payload = { participant_event_id: participant_event_id, exp: 1.hour.from_now.to_i }
    JWT.encode(payload, Rails.application.secret_key_base, "HS256")
  end

  def decode_state(state)
    payload = JWT.decode(state, Rails.application.secret_key_base, true, algorithm: "HS256")
    data = payload.first

    if data["exp"] < Time.current.to_i
      raise Error, "State token expired"
    end

    data["participant_event_id"]
  rescue JWT::DecodeError => e
    raise Error, "Invalid state token: #{e.message}"
  end

  private

  def post(method, params = {})
    response = Faraday.post("#{SLACK_API_BASE}/#{method}") do |req|
      req.headers["Authorization"] = "Bearer #{@bot_token}"
      req.headers["Content-Type"] = "application/json"
      req.body = params.to_json
    end

    raise RateLimited.new(retry_after(response)) if response.status == 429

    parsed = JSON.parse(response.body)
    raise RateLimited.new(retry_after(response)) if parsed["error"] == "ratelimited"

    parsed
  rescue Faraday::Error, JSON::ParserError => e
    raise TransportError, "Slack API error: #{e.message}"
  end

  def retry_after(response)
    response.headers["Retry-After"].to_i.clamp(1, 60)
  end
end
