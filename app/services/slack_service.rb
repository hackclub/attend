class SlackService
  SLACK_API_BASE = "https://slack.com/api"

  class Error < StandardError; end

  def initialize(bot_token: nil)
    @bot_token = bot_token || Rails.application.credentials.dig(:slack, :bot_token)
  end

  def invite_to_channel(channel_id:, user_id:)
    response = post("conversations.invite", channel: channel_id, users: user_id)

    if response["ok"]
      { success: true }
    elsif response["error"] == "already_in_channel"
      { success: true, already_member: true }
    else
      raise Error, "Failed to invite user to channel: #{response["error"]}"
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

    JSON.parse(response.body)
  rescue Faraday::Error, JSON::ParserError => e
    raise Error, "Slack API error: #{e.message}"
  end
end
