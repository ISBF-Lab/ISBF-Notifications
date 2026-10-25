# frozen_string_literal: true

require_relative "../../../support/android_browser_link_helpers"

RSpec.describe IsbfNotifications::AndroidBrowserLink::Register do
  include AndroidBrowserLinkHelpers

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:public_key) }
    it { is_expected.to validate_length_of(:public_key).is_at_most(2048) }
    it { is_expected.to allow_value(SecureRandom.hex(16)).for(:nonce) }
    it { is_expected.not_to allow_values(nil, "", "A" * 32, "a" * 31, "a" * 33).for(:nonce) }

    it "accepts a supported public RSA key" do
      is_expected.to allow_value(OpenSSL::PKey::RSA.new(2048).public_key.to_pem).for(:public_key)
    end

    it "rejects malformed, private, weak RSA and non-RSA keys" do
      is_expected.not_to allow_values(
        "not a public key",
        OpenSSL::PKey::RSA.new(2048).to_pem,
        OpenSSL::PKey::RSA.new(1024).public_key.to_pem,
        OpenSSL::PKey::EC.generate("prime256v1").public_to_pem,
      ).for(:public_key)
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:params) { { public_key:, nonce: } }
    let(:dependencies) { {} }
    let(:public_key) { OpenSSL::PKey::RSA.new(2048).public_key.to_pem }
    let(:nonce) { SecureRandom.hex(16) }

    before { SiteSetting.isbf_notifications_enabled = true }

    context "when the contract is invalid" do
      let(:nonce) { nil }

      it { is_expected.to fail_a_contract }
    end

    context "when the feature is disabled" do
      before { SiteSetting.isbf_notifications_enabled = false }

      it { is_expected.to fail_a_policy(:feature_enabled) }
    end

    context "when the registration is valid" do
      it "stores a short-lived hashed bearer and creates a public confirmation URL" do
        expect { result }.not_to change(UserApiKey, :count)
        expect(result).to run_successfully

        registration = result.registration
        stored =
          IsbfNotifications::AndroidBrowserLink::Registration.for_client(
            registration.data[:client_id],
          )
        query = Rack::Utils.parse_nested_query(URI.parse(registration.verification_url).query)

        expect(stored.data).to include(
          digest: ApiKey.hash_key(registration.token),
          application_name: I18n.t("isbf_notifications.android_browser_link.application_name"),
          public_key:,
          nonce:,
        )
        expect(stored.data.to_json).not_to include(registration.token)
        expect(registration.verification_url).not_to include(
          registration.token,
          stored.data[:digest],
        )
        expect(query).to include(
          "application_name" => stored.data[:application_name],
          "scopes" => "notifications,session_info",
          "padding" => "oaep",
          "nonce" => nonce,
          "public_key" => public_key,
        )
        expect(query).not_to have_key("android_device_token")
        expect(
          Discourse.redis.ttl(
            IsbfNotifications::AndroidBrowserLink::Registration.redis_key(stored.data[:digest]),
          ),
        ).to be_between(590, 600)
      end

      it "retains the original localized consent name when the current locale changes" do
        I18n.with_locale("zh_CN") { expect(result).to run_successfully }
        registration = result.registration
        stored =
          IsbfNotifications::AndroidBrowserLink::Registration.for_client(
            registration.data[:client_id],
          )

        I18n.with_locale("en") do
          query = Rack::Utils.parse_nested_query(URI.parse(registration.verification_url).query)

          expect(registration.data[:application_name]).to eq(
            I18n.t("isbf_notifications.android_browser_link.application_name", locale: "zh_CN"),
          )
          expect(stored.data[:application_name]).to eq(registration.data[:application_name])
          expect(query.fetch("application_name")).to eq(registration.data[:application_name])
        end
      end
    end
  end
end
