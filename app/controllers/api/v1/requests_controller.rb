module Api
  module V1
    class RequestsController < ApplicationController
      before_action :authenticate
      before_action :set_request, only: [:show, :cancel]

      # POST /api/v1/requests
      def create
        idempotency_key = request.headers["Idempotency-Key"]
        Rails.logger.tagged("key=#{idempotency_key}") do
          return render json: { error: "Missing Idempotency-Key" }, status: :bad_request if idempotency_key.blank?

          if params[:type].blank? || params[:external_id].blank?
            render json: { error: "Invalid payload" }, status: :bad_request and return
          end

          existing = Request.find_by(idempotency_key: idempotency_key)

          if existing
            return handle_existing_request(existing)
          end

          begin
            request_record = Request.create!(
              idempotency_key: idempotency_key,
              request_type: request_payload.delete(:type),
              external_id: request_payload.delete(:external_id),
              max_attempts: request_payload.delete(:retry_count) || 5,
              payload: request_payload,
              status: "pending"
            )
          rescue ActiveRecord::RecordNotUnique
            # race condition handling
            request_record = Request.find_by!(idempotency_key: idempotency_key)
            return handle_existing_request(request_record)
          end

          ApiRequestJob.perform_async(request_record.id)

          render json: serialize_request(request_record), status: :accepted
        end
      end

      # GET /api/v1/requests/:id
      def show
        render json: serialize_request(@request), status: :ok
      end

      # POST /api/v1/requests/:id/cancel
      def cancel
        Rails.logger.tagged("key=#{@request.idempotency_key}") do
          @request.with_lock do
            if @request.terminal?
              return render json: {
                error: "Cannot cancel a completed request",
                status: @request.status
              }, status: :conflict
            end

            @request.mark_aborted!
          end

          render json: serialize_request(@request), status: :ok
        end
      end

      private

      # -------------------------
      # Core Helpers
      # -------------------------

      def handle_existing_request(existing)
        unless existing.same_payload?(params[:type], params[:external_id])
          return render json: {
            error: "Idempotency key reuse with different payload"
          }, status: :conflict
        end

        http_status = existing.terminal? ? :ok : :accepted
        render json: serialize_request(existing), status: http_status
      end

      def serialize_request(req)
        {
          request_id: req.id,
          status: req.status,
          attempts: req.attempts,
          response: req.response,
          error_message: req.error_message
        }
      end

      def request_payload
        params.permit(:type, :external_id, :retry_count).to_h
      end

      def set_request
        @request = Request.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Request not found" }, status: :not_found
      end

      # -------------------------
      # Auth (simple bearer token)
      # -------------------------

      def authenticate
        token = Base64.decode64(request.headers["Authorization"]&.split(" ")&.last)

        unless token == ENV["API_KEY"]
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      end
    end
  end
end