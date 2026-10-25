# frozen_string_literal: true

require_relative "../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLinksController do
  include AndroidBrowserLinkHelpers

  let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:public_key) { private_key.public_key.to_pem }
  let(:nonce) { SecureRandom.hex(16) }

  before { SiteSetting.isbf_notifications_enabled = true }

  describe "#create" do
    it "creates a pending registration without setting a browser pairing cookie" do
      registration = register_android_browser(public_key:, nonce:)
      query = browser_approval_params(registration)

      expect(response.headers).to include(
        "Cache-Control" => "no-store",
        "Referrer-Policy" => "no-referrer",
      )
      expect(response.headers.fetch("Location")).to end_with(
        "/isbf/notifications/android-browser-links/poll.json",
      )
      expect(response.headers["Set-Cookie"].to_s).not_to include(
        IsbfNotifications::AndroidBrowserLink::COOKIE,
      )
      expect(registration).to include("version" => 1, "expires_in" => 600)
      expect(registration.fetch("android_device_token")).to match(/\A[a-f0-9]{64}\z/)
      expect(registration.fetch("verification_url")).not_to include(
        registration.fetch("android_device_token"),
      )
      expect(query).to include("scopes" => "notifications,session_info", "padding" => "oaep")
      expect(query.keys).to contain_exactly(
        "application_name",
        "client_id",
        "nonce",
        "padding",
        "public_key",
        "scopes",
      )
      expect(poll_android_browser(registration)).to include("status" => "pending", "revision" => 0)
    end

    it "rejects an invalid RSA key or nonce" do
      [{ public_key: "invalid", nonce: }, { public_key:, nonce: "invalid" }].each do |params|
        post "/isbf/notifications/android-browser-links.json", params:, as: :json
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "requires native JSON content rather than form input" do
      post "/isbf/notifications/android-browser-links.json", params: { public_key:, nonce: }

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects disabled-feature registrations" do
      SiteSetting.isbf_notifications_enabled = false
      post "/isbf/notifications/android-browser-links.json",
           params: {
             public_key:,
             nonce:,
           },
           as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "#poll" do
    it "rejects missing, malformed and forged device bearers" do
      [{}, { android_device_token: "bad" }].each do |params|
        post "/isbf/notifications/android-browser-links/poll.json", params:, as: :json
        expect(response).to have_http_status(:bad_request)
      end

      post "/isbf/notifications/android-browser-links/poll.json",
           params: {
             android_device_token: SecureRandom.hex(32),
           },
           as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns not found after an unapproved registration expires" do
      registration = register_android_browser(public_key:, nonce:)
      pending =
        IsbfNotifications::AndroidBrowserLink::Registration.for_client(
          registration.fetch("client_id"),
        )
      pending.remove!

      post "/isbf/notifications/android-browser-links/poll.json",
           params: {
             android_device_token: registration.fetch("android_device_token"),
           },
           as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "pauses a confirmed device when its exact browser login session expires" do
      user = Fabricate(:user)
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      sign_in(user)
      registration = register_android_browser(public_key:, nonce:)
      approve_android_browser(registration:)
      active = poll_android_browser(registration)
      grant = decrypted_browser_payload(private_key, active.fetch("payload"))
      key = UserApiKey.with_key(grant.fetch("key")).first!
      device =
        IsbfNotifications::AndroidBrowserLink::Device.from_token(
          registration.fetch("android_device_token"),
        )
      UserAuthToken.find(device.data[:auth_token_id]).update!(
        rotated_at: (SiteSetting.maximum_session_age + 1).hours.ago,
      )

      paused = poll_android_browser(registration)

      expect(paused).to include("status" => "signed_out", "revision" => 2)
      expect(key.reload.revoked_at).to be_present
      expect(decrypted_browser_payload(private_key, paused.fetch("payload"))).to eq(
        "paused" => true,
        "nonce" => nonce,
      )
    end
  end

  describe "#destroy" do
    fab!(:user)

    before do
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      sign_in(user)
    end

    it "disconnects a confirmed device and accepts repeated disconnects" do
      registration = register_android_browser(public_key:, nonce:)
      approve_android_browser(registration:)
      active = poll_android_browser(registration)
      grant = decrypted_browser_payload(private_key, active.fetch("payload"))
      key = UserApiKey.with_key(grant.fetch("key")).first!

      2.times do
        post "/isbf/notifications/android-browser-links/disconnect.json",
             params: {
               android_device_token: registration.fetch("android_device_token"),
             },
             as: :json
        expect(response).to have_http_status(:ok)
      end

      expect(poll_android_browser(registration)).to include("status" => "revoked", "revision" => 2)
      expect(key.reload.revoked_at).to be_present
    end

    it "rejects a forged disconnect bearer" do
      post "/isbf/notifications/android-browser-links/disconnect.json",
           params: {
             android_device_token: SecureRandom.hex(32),
           },
           as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
