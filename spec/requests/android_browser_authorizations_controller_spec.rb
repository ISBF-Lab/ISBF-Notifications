# frozen_string_literal: true

require_relative "../support/android_browser_link_helpers"

RSpec.describe UserApiKeysController do
  include AndroidBrowserLinkHelpers

  fab!(:user)

  let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:public_key) { private_key.public_key.to_pem }
  let(:nonce) { SecureRandom.hex(16) }
  let(:registration) { register_android_browser(public_key:, nonce:) }

  describe "#create" do
    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      SiteSetting.allow_user_api_key_scopes = "read|write|notifications|session_info"
      SiteSetting.force_https = false
      sign_in(user)
      registration
    end

    it "pairs through one ordinary Core website confirmation and exposes only encrypted credentials" do
      notification = Fabricate(:notification, user:)
      get "/user-api-key/new.json", params: browser_approval_params(registration)

      expect(response).to have_http_status(:ok)
      expect(poll_android_browser(registration)).to include("status" => "pending")
      expect { approve_android_browser(registration:) }.to change(UserApiKey, :count).by(1)

      approval_body = response.parsed_body
      cookie_header = response.headers["Set-Cookie"].to_s
      expect(approval_body).to have_key("redirect_url")
      expect(approval_body).not_to have_key("payload")
      expect(approval_body.fetch("redirect_url")).to start_with(
        "intent://isbf-one.com/isbf/notifications/android-return",
      )
      expect(approval_body.fetch("redirect_url")).not_to include(
        registration.fetch("android_device_token"),
      )
      expect(cookie_header).to include(IsbfNotifications::AndroidBrowserLink::COOKIE)
      expect(cookie_header).to match(/httponly/i)
      expect(cookie_header).to match(/samesite=lax/i)
      expect(cookie_header).not_to include(registration.fetch("android_device_token"))

      active = poll_android_browser(registration)
      grant = decrypted_browser_payload(private_key, active.fetch("payload"))
      key = UserApiKey.with_key(grant.fetch("key")).first!
      expect(active).to include(
        "version" => 1,
        "status" => "active",
        "revision" => 1,
        "notification_cursor" => notification.id,
      )
      expect(active).not_to have_key("key")
      expect(grant.fetch("nonce")).to eq(nonce)
      expect(key.user_id).to eq(user.id)
      expect(key.push_url).to eq(nil)
      expect(key.scopes.pluck(:name)).to contain_exactly("notifications", "session_info")
      expect(registration.fetch("verification_url")).not_to include(grant.fetch("key"))
      expect(cookie_header).not_to include(grant.fetch("key"))
    end

    it "rejects forged authorization parameters before issuing any key" do
      forged_parameters = [
        { "application_name" => "An unrelated notification application" },
        { "application_name" => "" },
        { "application_name" => nil },
        { "nonce" => SecureRandom.hex(16) },
        { "public_key" => OpenSSL::PKey::RSA.new(2048).public_key.to_pem },
        { "scopes" => "notifications,session_info,write" },
        { "scopes" => "notifications,notifications,session_info" },
        { "padding" => "pkcs1" },
        { "push_url" => "https://example.test/native-push" },
        { "auth_redirect" => "https://example.test/external-application" },
        {
          "client_id" =>
            "#{IsbfNotifications::AndroidBrowserLink::CLIENT_PREFIX}#{SecureRandom.uuid}",
        },
      ]

      forged_parameters.each do |overrides|
        expect do
          post "/user-api-key.json",
               params: browser_approval_params(registration).merge(overrides),
               as: :json
        end.not_to change(UserApiKey, :count)
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "accepts the registered consent name across different registration and browser languages" do
      locale_names = {}

      %w[en zh_CN].each do |registration_locale|
        SiteSetting.default_locale = registration_locale
        localized_registration =
          register_android_browser(browser: open_session, public_key:, nonce: SecureRandom.hex(16))
        pending =
          IsbfNotifications::AndroidBrowserLink::Registration.for_client(
            localized_registration.fetch("client_id"),
          )
        expected_name =
          I18n.t(
            "isbf_notifications.android_browser_link.application_name",
            locale: registration_locale,
          )
        query =
          Rack::Utils.parse_nested_query(
            URI.parse(localized_registration.fetch("verification_url")).query,
          )
        locale_names[registration_locale] = expected_name

        expect(pending.data[:application_name]).to eq(expected_name)
        expect(query.fetch("application_name")).to eq(expected_name)

        SiteSetting.allow_user_locale = true
        user.update!(locale: registration_locale == "en" ? "zh_CN" : "en")
        approve_android_browser(registration: localized_registration)

        expect(
          UserApiKeyClient.find_by!(
            client_id: localized_registration.fetch("client_id"),
          ).application_name,
        ).to eq(expected_name)
        expect(poll_android_browser(localized_registration)).to include("status" => "active")
      end

      expect(locale_names.values.uniq.size).to eq(2)
    end

    it "rejects approval after the registration's confirmation window expires" do
      pending =
        IsbfNotifications::AndroidBrowserLink::Registration.for_client(
          registration.fetch("client_id"),
        )
      pending.data[:expires_at] = 1.minute.ago.to_i
      pending.save!

      expect do
        post "/user-api-key.json", params: browser_approval_params(registration), as: :json
      end.not_to change(UserApiKey, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "requires a browser session even when an administrative API key is supplied" do
      admin = Fabricate(:admin)
      api_key = Fabricate(:api_key, user: admin)

      expect do
        post "/user-api-key.json",
             params: browser_approval_params(registration),
             headers: {
               "Api-Key" => api_key.key,
               "Api-Username" => admin.username,
             },
             as: :json
      end.not_to change(UserApiKey, :count)
      expect(response).to have_http_status(:forbidden)
      expect(poll_android_browser(registration)).to include("status" => "pending")
    end

    it "rejects consent authenticated using another user's application API key" do
      caller_key =
        Fabricate(
          :user_api_key,
          user:,
          scopes: [Fabricate.build(:user_api_key_scope, name: "write")],
        )

      expect do
        post "/user-api-key.json",
             params: browser_approval_params(registration),
             headers: {
               "User-Api-Key" => caller_key.key,
             },
             as: :json
      end.not_to change(UserApiKey, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "retains CSRF protection on the website approval action" do
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      expect do
        post "/user-api-key.json", params: browser_approval_params(registration), as: :json
      end.not_to change(UserApiKey, :count)
      expect(response).to have_http_status(:forbidden)
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    it "accepts website approval with a valid CSRF token" do
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      get "/session/csrf.json"
      csrf_token = response.parsed_body.fetch("csrf")

      post "/user-api-key.json",
           params: browser_approval_params(registration),
           headers: {
             "X-CSRF-Token" => csrf_token,
           },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(poll_android_browser(registration)).to include("status" => "active")
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    it "requires an explicit new registration when the same confirmation is replayed" do
      approve_android_browser(registration:)

      expect do
        post "/user-api-key.json", params: browser_approval_params(registration), as: :json
      end.not_to change(UserApiKey, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "preserves the ordinary Core API authorization flow for other applications" do
      params = {
        client_id: SecureRandom.hex(16),
        application_name: "An independent test application",
        public_key:,
        nonce:,
        scopes: "notifications,session_info",
        padding: "oaep",
      }

      post "/user-api-key.json", params:, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key("payload")
      grant = decrypted_browser_payload(private_key, response.parsed_body.fetch("payload"))
      expect(UserApiKey.with_key(grant.fetch("key")).first!.user_id).to eq(user.id)
      expect(response.headers["Set-Cookie"].to_s).not_to include(
        IsbfNotifications::AndroidBrowserLink::COOKIE,
      )
      expect(poll_android_browser(registration)).to include("status" => "pending")
    end
  end
end
