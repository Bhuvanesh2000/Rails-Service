class ApiRequestJob
  include Sidekiq::Job

  sidekiq_options retry: false # we control retries manually

  def perform(request_id)
    request = Request.find_by(id: request_id)
    return unless request

    Rails.logger.tagged("request_id=#{request.id}", "key=#{request.idempotency_key}") do
      Rails.logger.info("attemps: #{request.attempts}/#{request.max_attempts}")
      # -----------------------------
      # Step 1: Claim execution safely
      # -----------------------------
      return unless acquire_lock(request)
      return unless request_retryable(request)
      # -----------------------------
      # Step 2: Process request
      # -----------------------------
      result = simulate_external_call(request)
      Rails.logger.info("result: #{result}")
      if result[:status] == 200
        handle_success(request, result[:body])
        Rails.logger.info("response: #{request.response}")
      else
        handle_failure(request, result[:status])
        Rails.logger.info("error: #{request.error_message}")
      end
    end
  rescue StandardError => e
    handle_exception(request, e)
  end

  private

  # -----------------------------
  # Locking (critical section only)
  # -----------------------------
  def acquire_lock(request)
    request.with_lock do
      request.reload
      return false unless request.safe_to_process?

      request.mark_processing!
    end

    true
  end

  # -----------------------------
  # Retryable check
  # -----------------------------
  def request_retryable(request)
    request.with_lock do
      request.reload
      unless request.retryable?
        request.mark_failed!("Retry limit exceeded!")
        return false
      end
    end

    true
  end

  # -----------------------------
  # Success handling
  # -----------------------------
  def handle_success(request, response_body)
    request.with_lock do
      request.reload
      return if request.terminal?

      request.mark_succeeded!(response_body)
    end
  end

  # -----------------------------
  # Failure handling (retry logic)
  # -----------------------------
  def handle_failure(request, status_code)
    request.with_lock do
      request.reload
      return if request.terminal?

      request.increment_attempts!

      if retryable_status?(status_code) && request.retryable?
        request.mark_pending!("Retryable error: #{status_code}")
        reenqueue(request)
      else
        request.mark_failed!("Final failure: #{status_code}")
      end
    end
  end

  def handle_exception(request, error)
    return unless request

    request.with_lock do
      request.reload
      return if request.terminal?

      request.increment_attempts!

      if request.retryable?
        request.mark_pending!(error.message)
        reenqueue(request)
      else
        request.mark_failed!(error.message)
      end
    end
  end

  # -----------------------------
  # Retry mechanism
  # -----------------------------
  def reenqueue(request)
    delay = backoff_time(request.attempts)
    Rails.logger.info("reenqueued to run in #{delay} seconds")
    ApiRequestJob.perform_in(delay, request.id)
  end

  def backoff_time(attempts)
    (4**attempts).seconds
  end

  # -----------------------------
  # Retry rules (status-code level, stays in job)
  # -----------------------------
  def retryable_status?(status)
    [429, 500, 502, 503].include?(status)
  end

  # -----------------------------
  # Simulated external API
  # -----------------------------
  def simulate_external_call(request)
    case request.external_id % 5
    when 0
      {
        status: 200,
        body: fetch_real_data(request)
      }
    when 1
      { status: 500 }
    when 2
      { status: 429 }
    when 3
      { status: 403 }
    else
      { status: 400 }
    end
  end

  def fetch_real_data(request)
    {
      type: request.request_type,
      id: request.external_id,
      data: "Sample response"
    }
  end
end