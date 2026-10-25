# frozen_string_literal: true

module IsbfNotifications
  class AndroidBrowserLinksController < ::ApplicationController
    requires_plugin "isbf-notifications"
    skip_before_action :redirect_to_login_if_required, :check_xhr, :preload_json
    skip_before_action :verify_authenticity_token
    before_action :require_native_request
    before_action :rate_limit_device_requests
    before_action :prevent_caching

    def create
      AndroidBrowserLink::Register.call(service_params) do
        on_success do |registration:|
          render json: {
                   version: 1,
                   client_id: registration.data[:client_id],
                   android_device_token: registration.token,
                   verification_url: registration.verification_url,
                   expires_in: AndroidBrowserLink::REGISTRATION_TTL.to_i,
                 },
                 status: :created,
                 location: "/isbf/notifications/android-browser-links/poll.json"
        end
        on_failed_contract { raise Discourse::InvalidParameters.new(:base) }
        on_failure { raise Discourse::InvalidAccess }
      end
    end

    def poll
      AndroidBrowserLink::Read.call(service_params) do
        on_success do |device:|
          render json:
                   (
                     if device.is_a?(AndroidBrowserLink::Device)
                       device.snapshot
                     else
                       {
                         version: 1,
                         status: "pending",
                         client_id: device.data[:client_id],
                         revision: 0,
                       }
                     end
                   )
        end
        on_failed_contract { raise Discourse::InvalidParameters.new(:base) }
        on_model_not_found(:device) { raise Discourse::NotFound }
        on_failure { raise Discourse::InvalidAccess }
      end
    end

    def destroy
      AndroidBrowserLink::Disconnect.call(service_params) do
        on_success { render json: success_json }
        on_failed_contract { raise Discourse::InvalidParameters.new(:base) }
        on_model_not_found(:device) { raise Discourse::NotFound }
      end
    end

    private

    def require_native_request
      raise Discourse::InvalidAccess unless request.format.json? && request.content_mime_type&.json?
      if request.env["HTTP_USER_API_KEY"].present? || request.env["HTTP_API_KEY"].present?
        raise Discourse::InvalidAccess
      end
    end

    def rate_limit_device_requests
      limit = action_name == "create" ? 20 : 600
      RateLimiter.new(
        nil,
        "#{AndroidBrowserLink::STORE}:#{action_name}:#{request.remote_ip}",
        limit,
        1.minute,
      ).performed!
      if params[:android_device_token].present?
        RateLimiter.new(
          nil,
          "#{AndroidBrowserLink::STORE}:token:#{ApiKey.hash_key(params[:android_device_token].to_s)}",
          30,
          1.minute,
        ).performed!
      end
    end

    def prevent_caching
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end
  end
end
