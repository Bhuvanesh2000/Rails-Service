require "net/http"

class RequestService
  LOG_TAG = "RequestService".freeze

  def initialize
    @domain = ENV.fetch("DOMAIN")
    @base_path = "api/v1/requests"
    @username = ENV.fetch("USERNAME")
    @password = ENV.fetch("PASSWORD")
    @created_request_ids = []

    Rails.logger.info("[#{LOG_TAG}] Initialized — domain=#{@domain}")
  end

  # -------------------------------------------------------
  # Entry point: iterates through demo payloads,
  # creating requests via the API or cancelling the last one.
  # -------------------------------------------------------
  def process
    list = [
      { "type" => "user", "external_id" => 1, "retry_count" => 5 },
      { "type" => "user", "external_id" => 2, "retry_count" => 4 },
      { "type" => "user", "external_id" => 3, "retry_count" => 3 },
      { "type" => "user", "external_id" => 4, "retry_count" => 2 },
      { "cancel" => true },
      { "type" => "user", "external_id" => 5, "retry_count" => 1 },
      { "cancel" => true },
      { "type" => "Order", "external_id" => 1, "retry_count" => 5 },
      { "type" => "Order", "external_id" => 2, "retry_count" => 4 },
      { "type" => "Order", "external_id" => 3, "retry_count" => 3 },
      { "type" => "Order", "external_id" => 4, "retry_count" => 2 },
      { "type" => "Order", "external_id" => 5, "retry_count" => 1 },
      { "type" => "Item", "external_id" => 1, "retry_count" => 5 },
      { "type" => "Item", "external_id" => 2, "retry_count" => 4 },
      { "type" => "Item", "external_id" => 3, "retry_count" => 3 },
      { "cancel" => true },
      { "type" => "Item", "external_id" => 4, "retry_count" => 2 },
      { "type" => "Item", "external_id" => 5, "retry_count" => 1 }
    ]

    Rails.logger.info("[#{LOG_TAG}] Starting demo with #{list.size} entries")
    Rails.logger.info("[#{LOG_TAG}] #{'=' * 60}")

    list.each_with_index do |payload, index|
      Rails.logger.info("[#{LOG_TAG}] [#{index + 1}/#{list.size}] #{payload.inspect}")

      if payload["cancel"]
        cancel_last_request
      else
        send_request(payload)
      end

      Rails.logger.info("[#{LOG_TAG}] #{'-' * 40}")
    end

    Rails.logger.info("[#{LOG_TAG}] #{'=' * 60}")
    Rails.logger.info("[#{LOG_TAG}] Demo complete! Total requests created: #{@created_request_ids.size}")
  end

  private

  # -------------------------------------------------------
  # POST /api/v1/requests — create a new request
  # -------------------------------------------------------
  def send_request(body)
    uri = URI("#{@domain}/#{@base_path}")
    idempotency_key = SecureRandom.uuid

    Rails.logger.info("[#{LOG_TAG}] POST #{uri} | key=#{idempotency_key} | body=#{body.to_json}")

    req = Net::HTTP::Post.new(uri)
    req.basic_auth(@username, @password)
    req["Content-Type"] = "application/json"
    req["Idempotency-Key"] = idempotency_key
    req.body = body.to_json

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    Rails.logger.info("[#{LOG_TAG}] Response: #{response.code} #{response.body}")

    parsed = JSON.parse(response.body) rescue {}
    if parsed["request_id"]
      @created_request_ids << parsed["request_id"]
      Rails.logger.info("[#{LOG_TAG}] ✅ Created request ##{parsed['request_id']} (status=#{parsed['status']})")
    else
      Rails.logger.error("[#{LOG_TAG}] ❌ Create failed: #{parsed['error']}")
    end
  end

  # -------------------------------------------------------
  # POST /api/v1/requests/:id/cancel — cancel last request
  # -------------------------------------------------------
  def cancel_last_request
    if @created_request_ids.empty?
      Rails.logger.warn("[#{LOG_TAG}] ⚠️  Cancel requested but no previous requests to cancel")
      return
    end

    last_id = @created_request_ids.last
    uri = URI("#{@domain}/#{@base_path}/#{last_id}/cancel")

    Rails.logger.info("[#{LOG_TAG}] 🚫 POST #{uri} | Cancelling request ##{last_id}")

    req = Net::HTTP::Post.new(uri)
    req.basic_auth(@username, @password)
    req["Content-Type"] = "application/json"

    response = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    Rails.logger.info("[#{LOG_TAG}] Response: #{response.code} #{response.body}")

    parsed = JSON.parse(response.body) rescue {}
    if response.code.to_i == 200
      Rails.logger.info("[#{LOG_TAG}] ✅ Request ##{last_id} cancelled (status=#{parsed['status']})")
    else
      Rails.logger.warn("[#{LOG_TAG}] ⚠️  Cancel failed for ##{last_id}: #{parsed['error']}")
    end
  end
end
