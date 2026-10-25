# frozen_string_literal: true

require_relative "../support/android_browser_link_helpers"

RSpec.describe SessionController do
  include AndroidBrowserLinkHelpers

  fab!(:first_user, :user)
  fab!(:second_user, :user)

  let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:public_key) { private_key.public_key.to_pem }
  let(:nonce) { SecureRandom.hex(16) }
  let(:registration) { register_android_browser(public_key:, nonce:) }
  let(:initial_state) { poll_android_browser(registration) }
  let(:initial_grant) { decrypted_browser_payload(private_key, initial_state.fetch("payload")) }
  let(:initial_key) { UserApiKey.with_key(initial_grant.fetch("key")).first! }

  before do
    SiteSetting.isbf_notifications_enabled = true
    SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
    SiteSetting.force_https = false
    SiteSetting.log_out_strict = false
  end

  describe "#become" do
    before do
      sign_in(first_user)
      approve_android_browser(registration:)
      initial_key
    end

    it "switches device notifications from account A to account B through the normal browser login" do
      notification = Fabricate(:notification, user: second_user)

      expect { sign_in(second_user) }.to change(UserApiKey, :count).by(1)
      expect(response).to have_http_status(:found)
      active = poll_android_browser(registration)
      grant = decrypted_browser_payload(private_key, active.fetch("payload"))
      next_key = UserApiKey.with_key(grant.fetch("key")).first!

      expect(active).to include(
        "status" => "active",
        "revision" => 2,
        "notification_cursor" => notification.id,
      )
      expect(next_key.user_id).to eq(second_user.id)
      expect(next_key.scopes.pluck(:name)).to contain_exactly("notifications", "session_info")
      expect(initial_key.reload.revoked_at).to be_present
      expect(grant.fetch("nonce")).to eq(nonce)
      expect(notification.reload.read).to eq(false)
    end

    it "keeps one active key and revision on repeated login to the same account" do
      expect { sign_in(first_user) }.not_to change(UserApiKey, :count)

      expect(poll_android_browser(registration)).to include(
        "status" => "active",
        "revision" => 1,
        "payload" => initial_state.fetch("payload"),
      )
      expect(initial_key.reload.revoked_at).to eq(nil)
    end

    it "resumes the paired device after logout and a later browser login" do
      delete "/session/#{first_user.encoded_username}.json", xhr: true
      expect(poll_android_browser(registration)).to include(
        "status" => "signed_out",
        "revision" => 2,
      )

      sign_in(second_user)

      active = poll_android_browser(registration)
      grant = decrypted_browser_payload(private_key, active.fetch("payload"))
      expect(active).to include("status" => "active", "revision" => 3)
      expect(UserApiKey.with_key(grant.fetch("key")).first!.user_id).to eq(second_user.id)
      expect(initial_key.reload.revoked_at).to be_present
    end

    it "follows a standalone browser window while isolating a different browser's pairing cookie" do
      other_browser = open_session
      other_browser.get "/session/#{second_user.encoded_username}/become"
      other_registration =
        register_android_browser(browser: other_browser, public_key:, nonce: SecureRandom.hex(16))
      approve_android_browser(browser: other_browser, registration: other_registration)

      other_browser.get "/session/#{first_user.encoded_username}/become"
      other_state = poll_android_browser(other_registration, browser: other_browser)
      other_grant = decrypted_browser_payload(private_key, other_state.fetch("payload"))
      expect(other_state).to include("status" => "active", "revision" => 2)
      expect(UserApiKey.with_key(other_grant.fetch("key")).first!.user_id).to eq(first_user.id)
      expect(poll_android_browser(registration)).to include("status" => "active", "revision" => 1)

      sign_in(second_user)

      own_state = poll_android_browser(registration)
      own_grant = decrypted_browser_payload(private_key, own_state.fetch("payload"))
      expect(UserApiKey.with_key(own_grant.fetch("key")).first!.user_id).to eq(second_user.id)
      expect(poll_android_browser(other_registration, browser: other_browser)).to include(
        "status" => "active",
        "revision" => 2,
        "payload" => other_state.fetch("payload"),
      )
    end

    it "keeps manual revocation permanent across later account changes" do
      post "/user-api-key/revoke.json", params: { id: initial_key.id }, as: :json
      expect(response).to have_http_status(:ok)

      expect { sign_in(second_user) }.not_to change(UserApiKey, :count)
      expect(poll_android_browser(registration)).to include("status" => "revoked", "revision" => 2)

      expect { sign_in(first_user) }.not_to change(UserApiKey, :count)
      expect(poll_android_browser(registration)).to include("status" => "revoked", "revision" => 2)
    end

    it "preserves normal website login when a pairing cookie is invalid" do
      cookies[IsbfNotifications::AndroidBrowserLink::COOKIE] = SecureRandom.hex(32)

      expect { sign_in(second_user) }.not_to change(UserApiKey, :count)
      get "/session/current.json"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("current_user").fetch("id")).to eq(second_user.id)
      expect(initial_key.reload.revoked_at).to eq(nil)
    end
  end

  describe "#destroy" do
    before do
      sign_in(first_user)
      approve_android_browser(registration:)
      initial_key
    end

    it "pauses the direct device while preserving other clients, subscriptions, notifications and delivery policy" do
      subscription = Fabricate(:push_subscription, user: first_user)
      other_subscription = Fabricate(:push_subscription, user: second_user)
      other_key = Fabricate(:isbf_android_browser_key, user: first_user)
      notification = Fabricate(:notification, user: first_user)
      subscriptions_before = PushSubscription.order(:id).map(&:attributes)
      notification_before = notification.reload.attributes
      other_key_before = other_key.reload.attributes
      email_count = Jobs::UserEmail.jobs.size
      push_count = Jobs::DeliverPushNotification.jobs.size
      event_setting = SiteSetting.isbf_device_push_replied

      delete "/session/#{first_user.encoded_username}.json", xhr: true

      expect(response).to have_http_status(:ok)
      paused = poll_android_browser(registration)
      expect(paused).to include("status" => "signed_out", "revision" => 2)
      expect(decrypted_browser_payload(private_key, paused.fetch("payload"))).to eq(
        "paused" => true,
        "nonce" => nonce,
      )
      expect(initial_key.reload.revoked_at).to be_present
      expect(other_key.reload.attributes).to eq(other_key_before)
      expect(PushSubscription.order(:id).map(&:attributes)).to eq(subscriptions_before)
      expect(PushSubscription.where(id: [subscription.id, other_subscription.id]).count).to eq(2)
      expect(notification.reload.attributes).to eq(notification_before)
      expect(Jobs::UserEmail.jobs.size).to eq(email_count)
      expect(Jobs::DeliverPushNotification.jobs.size).to eq(push_count)
      expect(SiteSetting.isbf_device_push_replied).to eq(event_setting)
    end
  end
end
