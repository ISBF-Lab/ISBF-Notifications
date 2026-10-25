# frozen_string_literal: true

require_relative "../../../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLink::Disconnect do
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

    before { device }

    context "when the contract is invalid" do
      let(:params) { { android_device_token: nil } }

      it { is_expected.to fail_a_contract }
    end

    context "when the bearer is forged" do
      let(:params) { { android_device_token: SecureRandom.hex(32) } }

      it { is_expected.to fail_to_find_a_model(:device) }
    end

    context "when the device disconnects" do
      it "revokes only this client's keys even when the feature is disabled" do
        SiteSetting.isbf_notifications_enabled = false
        unrelated_key = Fabricate(:isbf_android_browser_key, user:)

        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(key.reload.revoked_at).to be_present
        expect(unrelated_key.reload.revoked_at).to eq(nil)
        expect(
          IsbfNotifications::AndroidBrowserLink::Device.find(device.digest).snapshot,
        ).to include(status: "revoked", revision: 2)
      end
    end

    context "when the device has already disconnected" do
      before { device.disconnect! }

      it "keeps the same revoked revision on repeated disconnect" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully
        expect(
          IsbfNotifications::AndroidBrowserLink::Device.find(device.digest).snapshot,
        ).to include(status: "revoked", revision: 2)
      end
    end
  end
end
