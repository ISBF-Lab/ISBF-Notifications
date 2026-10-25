# frozen_string_literal: true

require_relative "../../../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLink::Synchronize do
  include AndroidBrowserLinkHelpers

  describe described_class::Contract, type: :model do
    it { is_expected.to allow_value(SecureRandom.hex(32)).for(:browser_key) }
    it { is_expected.not_to allow_values(nil, "", "A" * 64, "a" * 63, "a" * 65).for(:browser_key) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:paired_user, :user)
    fab!(:acting_user) { paired_user }

    let(:params) { { browser_key: device.digest } }
    let(:dependencies) do
      { guardian: acting_user.guardian, options: { auth_token_id: next_auth_token.id } }
    end
    let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:nonce) { SecureRandom.hex(16) }
    let(:registration) do
      browser_link_registration(public_key: private_key.public_key.to_pem, nonce:)
    end
    let(:client) do
      Fabricate(
        :user_api_key_client,
        client_id: registration.data[:client_id],
        public_key: private_key.public_key.to_pem,
        scopes: IsbfNotifications::AndroidBrowserLink::SCOPES,
      )
    end
    let(:key) { Fabricate(:isbf_android_browser_key, user: paired_user, client:) }
    let(:auth_token) { Fabricate(:isbf_android_browser_auth_token, user: paired_user) }
    let(:next_auth_token) { Fabricate(:isbf_android_browser_auth_token, user: acting_user) }
    let(:payload) { encrypted_browser_payload(private_key, { key: key.key, nonce: }) }
    let(:device) { persist_browser_link(registration:, key:, auth_token:, payload:) }

    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      device
    end

    context "when the contract is invalid" do
      let(:params) { { browser_key: nil } }

      it { is_expected.to fail_a_contract }
    end

    context "when the feature is disabled" do
      before { SiteSetting.isbf_notifications_enabled = false }

      it { is_expected.to fail_a_policy(:feature_enabled) }
    end

    context "when the browser cookie is forged" do
      let(:params) { { browser_key: SecureRandom.hex(32) } }

      it { is_expected.to fail_to_find_a_model(:device) }
    end

    context "when the device was disconnected" do
      before { device.disconnect! }

      it "requires a new explicit pairing instead of silently issuing another key" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to fail_a_policy(:browser_is_paired)
        expect(
          IsbfNotifications::AndroidBrowserLink::Device.find(device.digest).snapshot[:status],
        ).to eq("revoked")
      end
    end

    context "when the device pairing has expired" do
      before do
        device.data[:expires_at] = 1.minute.ago.to_i
        device.save!
      end

      it { is_expected.to fail_a_policy(:browser_is_paired) }
    end

    context "when the same account logs in again" do
      it "retains the existing grant and revision while following the new browser session" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully

        stored = IsbfNotifications::AndroidBrowserLink::Device.find(device.digest)
        expect(stored.snapshot).to include(status: "active", revision: 1, payload:)
        expect(stored.data).to include(key_id: key.id, auth_token_id: next_auth_token.id)
        expect(key.reload.revoked_at).to eq(nil)
      end
    end

    context "when the browser switches to another account" do
      fab!(:acting_user, :user)

      it "revokes account A's grant and encrypts only a scoped account B grant" do
        notification = Fabricate(:notification, user: acting_user)
        unrelated_key = Fabricate(:isbf_android_browser_key, user: paired_user)

        expect { result }.to change(UserApiKey, :count).by(1)
        expect(result).to run_successfully

        stored = IsbfNotifications::AndroidBrowserLink::Device.find(device.digest)
        payload = decrypted_browser_payload(private_key, stored.snapshot[:payload])
        current_key = UserApiKey.with_key(payload.fetch("key")).first!
        expect(stored.snapshot).to include(
          status: "active",
          revision: 2,
          notification_cursor: notification.id,
        )
        expect(stored.data).to include(user_id: acting_user.id, auth_token_id: next_auth_token.id)
        expect(key.reload.revoked_at).to be_present
        expect(unrelated_key.reload.revoked_at).to eq(nil)
        expect(current_key).to have_attributes(
          user_id: acting_user.id,
          user_api_key_client_id: client.id,
        )
        expect(current_key.scopes.pluck(:name)).to contain_exactly("notifications", "session_info")
        expect(payload.fetch("nonce")).to eq(nonce)
      end
    end

    context "when the browser signs out" do
      let(:dependencies) { { guardian: Guardian.new } }

      it "pauses notifications and invalidates the previous account key" do
        expect(result).to run_successfully
        stored = IsbfNotifications::AndroidBrowserLink::Device.find(device.digest)

        expect(stored.snapshot).to include(status: "signed_out", revision: 2)
        expect(stored.data[:user_id]).to eq(nil)
        expect(key.reload.revoked_at).to be_present
        expect(decrypted_browser_payload(private_key, stored.snapshot[:payload])).to eq(
          "paused" => true,
          "nonce" => nonce,
        )
      end
    end

    context "when the signed-out browser logs in again" do
      before { device.synchronize!(nil) }

      it "resumes the pairing using a fresh scoped grant" do
        expect { result }.to change(UserApiKey, :count).by(1)
        expect(result).to run_successfully
        stored = IsbfNotifications::AndroidBrowserLink::Device.find(device.digest)
        expect(stored.snapshot).to include(status: "active", revision: 3)
        expect(stored.data).to include(user_id: acting_user.id, auth_token_id: next_auth_token.id)
        expect(key.reload.revoked_at).to be_present
      end
    end

    context "when the user has manually revoked the active key" do
      fab!(:acting_user, :user)

      before { key.update!(revoked_at: Time.zone.now) }

      it "keeps the device revoked across a browser account switch" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(
          IsbfNotifications::AndroidBrowserLink::Device.find(device.digest).snapshot,
        ).to include(status: "revoked", revision: 2)
      end
    end
  end
end
