class Request < ApplicationRecord
  # -----------------------------
  # Enums / Constants
  # -----------------------------
  STATUSES = %w[pending processing succeeded failed aborted].freeze

  # -----------------------------
  # Validations
  # -----------------------------
  validates :idempotency_key, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :request_type, presence: true
  validates :external_id, presence: true

  validates :attempts, numericality: { greater_than_or_equal_to: 0 }
  validates :max_attempts, numericality: { greater_than: 0 }

  # -----------------------------
  # Scopes (useful for debugging / ops)
  # -----------------------------
  scope :pending, -> { where(status: "pending") }
  scope :processing, -> { where(status: "processing") }
  scope :succeeded, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
  scope :aborted, -> { where(status: "aborted") }

  # Stuck jobs (important for ops)
  scope :stale, ->(timeout = 5.minutes.ago) {
    where(status: "processing").where("locked_at < ?", timeout)
  }

  # -----------------------------
  # State helpers
  # -----------------------------
  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  def aborted?
    status == "aborted"
  end

  def terminal?
    succeeded? || failed? || aborted?
  end

  # -----------------------------
  # Transition helpers (important)
  # -----------------------------
  def mark_processing!
    update!(
      status: "processing",
      locked_at: Time.current
    )
  end

  def mark_succeeded!(response_body)
    update!(
      status: "succeeded",
      response: response_body,
      error_message: nil
    )
  end

  def mark_pending!(error_message = nil)
    update!(
      status: "pending",
      error_message: error_message,
      locked_at: nil
    )
  end

  def mark_failed!(error_message)
    update!(
      status: "failed",
      error_message: error_message
    )
  end

  def mark_aborted!
    update!(status: "aborted")
  end

  def increment_attempts!
    increment!(:attempts)
  end

  # -----------------------------
  # Retry logic helpers
  # -----------------------------
  def retryable?
    attempts < max_attempts && !terminal?
  end

  # -----------------------------
  # Idempotency validation (core logic)
  # -----------------------------
  def same_payload?(incoming_type, incoming_external_id)
    request_type == incoming_type &&
      external_id == incoming_external_id
  end

  # -----------------------------
  # Safe transition guard
  # -----------------------------
  def safe_to_process?
    return false if terminal?

    if processing? && locked_at.present? && locked_at > 30.seconds.ago
      return false
    end

    true
  end
end