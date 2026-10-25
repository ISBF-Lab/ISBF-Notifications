# frozen_string_literal: true

Fabricator(:isbf_android_browser_auth_token, class_name: "UserAuthToken") do
  user
  auth_token { UserAuthToken.hash_token(SecureRandom.hex(16)) }
  prev_auth_token { |attributes| attributes[:auth_token] }
  rotated_at { Time.zone.now }
end

Fabricator(:isbf_android_browser_key, from: :user_api_key) do
  scopes do
    IsbfNotifications::AndroidBrowserLink::SCOPES.map do |name|
      Fabricate.build(:user_api_key_scope, name:)
    end
  end
  expires_at { 90.days.from_now }
end
