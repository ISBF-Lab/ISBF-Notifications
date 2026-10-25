# frozen_string_literal: true

require_relative "../../../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLink::Complete do
  include AndroidBrowserLinkHelpers

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:client_id) }
    it { is_expected.to validate_presence_of(:payload) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:user)

    let(:params) { { client_id:, payload: } }
    let(:dependencies) { { guardian: user.guardian, options: { auth_token_id: auth_token.id } } }
    let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:public_key) { private_key.public_key.to_pem }
    let(:nonce) { SecureRandom.hex(16) }
    let(:registration) { browser_link_registration(public_key:, nonce:) }
    let(:client_id) { registration.data[:client_id] }
    let(:client) { Fabricate(:user_api_key_client, client_id:) }
    let(:key) { Fabricate(:isbf_android_browser_key, user:, client:) }
    let(:auth_token) { Fabricate(:isbf_android_browser_auth_token, user:) }
    let(:payload) { encrypted_browser_payload(private_key, { key: "test-key", nonce: }) }

    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      registration
      client
      key
    end

    context "when the contract is invalid" do
      let(:payload) { nil }

      it { is_expected.to fail_a_contract }
    end

    context "when the pending registration is missing" do
      let(:client_id) do
        "#{IsbfNotifications::AndroidBrowserLink::CLIENT_PREFIX}#{SecureRandom.uuid}"
      end

      it { is_expected.to fail_to_find_a_model(:registration) }
    end

    context "when the browser has no authenticated session" do
      let(:dependencies) { { guardian: user.guardian, options: { auth_token_id: 0 } } }

      it { is_expected.to fail_a_policy(:can_follow_browser) }
    end

    context "when the feature is disabled" do
      before { SiteSetting.isbf_notifications_enabled = false }

      it { is_expected.to fail_a_policy(:can_follow_browser) }
    end

    context "when the Core client is missing" do
      let(:client) { nil }
      let(:key) { nil }

      it { is_expected.to fail_to_find_a_model(:client) }
    end

    context "when the browser user's Core grant is missing" do
      let(:key) { nil }

      it { is_expected.to fail_to_find_a_model(:key) }
    end

    context "when the browser approves the pairing" do
      it "persists the encrypted grant, session and notification high-water mark" do
        notification = Fabricate(:notification, user:)

        expect(result).to run_successfully

        device = IsbfNotifications::AndroidBrowserLink::Device.from_token(registration.token)
        expect(device.snapshot).to include(
          status: "active",
          revision: 1,
          notification_cursor: notification.id,
          payload:,
        )
        expect(device.data).to include(
          user_id: user.id,
          key_id: key.id,
          auth_token_id: auth_token.id,
        )
        expect(client.reload).to have_attributes(public_key:)
        expect(client.scopes.pluck(:name)).to contain_exactly("notifications", "session_info")
        expect(key.reload.expires_at).to be_within(1.second).of(90.days.from_now)
        expect(IsbfNotifications::AndroidBrowserLink::Registration.for_client(client_id)).to eq(nil)
      end

      it "revokes only the previous paired device when this browser pairs again" do
        previous_registration = browser_link_registration(public_key:, nonce: SecureRandom.hex(16))
        previous_client =
          Fabricate(:user_api_key_client, client_id: previous_registration.data[:client_id])
        previous_key = Fabricate(:isbf_android_browser_key, user:, client: previous_client)
        previous =
          persist_browser_link(
            registration: previous_registration,
            key: previous_key,
            auth_token:,
            payload:,
          )
        dependencies[:options][:previous_browser_key] = previous.digest

        expect(result).to run_successfully
        expect(previous_key.reload.revoked_at).to be_present
        expect(key.reload.revoked_at).to eq(nil)
        expect(
          IsbfNotifications::AndroidBrowserLink::Device.find(previous.digest).snapshot[:status],
        ).to eq("revoked")
      end
    end
  end
end
