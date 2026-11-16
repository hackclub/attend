# Development-only: makes the local server behave like a busy production box
# on a poor connection, so loading states can be seen and judged. Off unless
# SIMULATE_LATENCY is set (see config/environments/development.rb).
#
#   SIMULATE_LATENCY=1 bin/dev
#
# Every request waits a round trip (network). Page requests then wait as if
# the server were queueing (server), and requests for a lazy section — the
# slow parts of a page — wait longer still (frame), with jitter so sections
# land one at a time the way they do in production. HTML bodies are then
# trickled out at a capped bandwidth. Assets get the round trip only, so
# the page shell still paints.
#
# Tune with SIMULATE_LATENCY_NETWORK_MS, _SERVER_MS, _FRAME_MS and _KBPS.
class SimulatedLatency
  def initialize(app, network_ms: 250, server_ms: 900, frame_ms: 3500, kbps: 256)
    @app = app
    @network = env_ms("NETWORK_MS", network_ms)
    @server = env_ms("SERVER_MS", server_ms)
    @frame = env_ms("FRAME_MS", frame_ms)
    @bytes_per_second = env_ms("KBPS", kbps) * 1024 / 8
  end

  def call(env)
    pause(@network)

    status, headers, body = @app.call(env)
    return [ status, headers, body ] unless html?(headers)

    if env["HTTP_TURBO_FRAME"].present?
      pause(@frame * rand(0.5..1.3))
    elsif env["REQUEST_METHOD"] == "GET"
      pause(@server * rand(0.7..1.3))
    else
      pause(@server * rand(1.0..2.0))
    end

    [ status, headers, Trickle.new(body, @bytes_per_second) ]
  end

  private

  def env_ms(name, default)
    Integer(ENV.fetch("SIMULATE_LATENCY_#{name}", default))
  end

  def html?(headers)
    headers["content-type"].to_s.start_with?("text/html", "text/vnd.turbo-stream")
  end

  def pause(ms)
    sleep(ms / 1000.0) if ms.positive?
  end

  # Hands the body on in small slices, sleeping between them, so a big page
  # arrives the way it would over a slow link instead of all at once.
  class Trickle
    SLICE = 4 * 1024

    def initialize(body, bytes_per_second)
      @body = body
      @bytes_per_second = bytes_per_second
    end

    def each
      @body.each do |chunk|
        chunk.each_char.each_slice(SLICE) do |slice|
          yield slice.join
          sleep(SLICE.to_f / @bytes_per_second) if @bytes_per_second.positive?
        end
      end
    end

    def close
      @body.close if @body.respond_to?(:close)
    end
  end
end
