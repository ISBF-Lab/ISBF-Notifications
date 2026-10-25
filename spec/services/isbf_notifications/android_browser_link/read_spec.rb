# frozen_string_literal: true

require_relative "../../../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLink::Read do
  include AndroidBrowserLinkHelpers

  describe described_class::Contract, type: :model do
    it { is_expected.to allow_value(SecureRandom.hex(32)).for(:android_device_token) }

    it do
      is_expected.not_to allow_values(nil, "", "A" * 64, "a" * 63, "a" * 65).for(
        :android_device_token,
      )
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:user)

    let(:params) { { android_device_token: registration.token } }
    let(:dependencies) { {} }
    let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:nonce) { SecureRandom.hex(16) }
    let(:registration) do
      browser_link_registration(public_key: private_key.public_key.to_pem, nonce:)
    end
    let(:client) { Fabricate(:user_api_key_client, client_id: registration.data[:client_id]) }
    let(:key) { Fabricate(:isbf_android_browser_key, user:, client:) }
    let(:auth_token) { Fabricate(:isbf_android_browser_auth_token, user:) }
    let(:payload) { encrypted_browser_payload(private_key, { key: key.key, nonce: }) }
    let(:device) { persist_browser_link(registration:, key:, auth_token:, payload:) }

    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.user_api_key_allowed_groups = Group::AUTO_GROUPS[:everyone].to_s
      registration
      device
    end

    context "when the contract is invalid" do
      let(:params) { { android_device_token: nil } }

      it { is_expected.to fail_a_contract }
    end

    context "when the feature is disabled" do
      before { SiteSetting.isbf_notifications_enabled = false }

      it { is_expected.to fail_a_policy(:feature_enabled) }
    end

    context "when the bearer is forged" do
      let(:params) { { android_device_token: SecureRandom.hex(32) } }

      it { is_expected.to fail_to_find_a_model(:device) }
    end

    context "when the browser has not approved the registration" do
      let(:device) { nil }

      it "returns pending without issuing a website API key" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(result.device.data[:client_id]).to eq(registration.data[:client_id])
      end
    end

    context "when the pending registration expires" do
      let(:device) { nil }

      before { registration.remove! }

      it { is_expected.to fail_to_find_a_model(:device) }
    end

    context "when the active grant is valid" do
      it "returns the encrypted grant without changing revision or notification state" do
        notification = Fabricate(:notification, user:)

        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(result.device.snapshot).to include(status: "active", revision: 1, payload:)
        expect(notification.reload.read).to eq(false)
        expect(decrypted_browser_payload(private_key, result.device.snapshot[:payload])).to include(
          "key" => key.key,
          "nonce" => nonce,
        )
      end
    end

    context "when the user manually revokes the notification key" do
      before { key.update!(revoked_at: Time.zone.now) }

      it "reports permanent revocation with an encrypted pause command" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(result.device.snapshot).to include(status: "revoked", revision: 2)
        expect(decrypted_browser_payload(private_key, result.device.snapshot[:payload])).to eq(
          "paused" => true,
          "nonce" => nonce,
        )
      end
    end

    context "when the corresponding website session expires" do
      before { auth_token.update!(rotated_at: (SiteSetting.maximum_session_age + 1).hours.ago) }

      it "pauses device notifications and revokes the old grant" do
        expect(result).to run_successfully
        expect(result.device.snapshot).to include(status: "signed_out", revision: 2)
        expect(key.reload.revoked_at).to be_present
        expect(result.device.data[:user_id]).to eq(nil)
        expect(decrypted_browser_payload(private_key, result.device.snapshot[:payload])).to eq(
          "paused" => true,
          "nonce" => nonce,
        )
      end
    end

    context "when the paired user is suspended" do
      before { user.update!(suspended_till: 1.day.from_now) }

      it "pauses the device instead of returning an active grant" do
        expect(result).to run_successfully
        expect(result.device.snapshot[:status]).to eq("signed_out")
        expect(key.reload.revoked_at).to be_present
      end
    end

    context "when the device pairing has expired" do
      before do
        device.data[:expires_at] = 1.minute.ago.to_i
        device.save!
      end

      it "reports expiry without issuing a new grant" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(result.device.snapshot[:status]).to eq("expired")
      end
    end
  end
end
