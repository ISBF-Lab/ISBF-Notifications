# frozen_string_literal: true

module AndroidBrowserLinkHelpers
  def browser_link_registration(public_key:, nonce:)
    IsbfNotifications::AndroidBrowserLink::Registration.prepare(public_key:, nonce:).tap(&:save!)
  end

  def encrypted_browser_payload(private_key, payload)
    Base64.strict_encode64(
      private_key.public_encrypt(payload.to_json, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING),
    )
  end

  def decrypted_browser_payload(private_key, payload)
    JSON.parse(
      private_key.private_decrypt(Base64.decode64(payload), OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING),
    )
  end

  def persist_browser_link(registration:, key:, auth_token:, payload:, **attributes)
    if key.client.client_id != registration.data[:client_id]
      raise ArgumentError, "The device fixture must own its Core client"
    end

    IsbfNotifications::AndroidBrowserLink::Device.new(
      registration.data[:digest],
      registration
        .data
        .except(:digest)
        .merge(
          status: "active",
          revision: 1,
          user_id: key.user_id,
          key_id: key.id,
          auth_token_id: auth_token.id,
          payload:,
          notification_cursor: 0,
          expires_at: 90.days.from_now.to_i,
          **attributes,
        ),
    ).tap(&:save!)
  end

  def register_android_browser(browser: self, public_key:, nonce:)
    browser.post "/isbf/notifications/android-browser-links.json",
                 params: {
                   public_key:,
                   nonce:,
                 },
                 as: :json
    expect(browser.response).to have_http_status(:created)
    browser.response.parsed_body
  end

  def browser_approval_params(registration)
    params = Rack::Utils.parse_nested_query(URI.parse(registration.fetch("verification_url")).query)
    pending =
      IsbfNotifications::AndroidBrowserLink::Registration.for_client(
        registration.fetch("client_id"),
      )
    params["application_name"] = pending.data.fetch(:application_name) if pending
    params
  end

  def approve_android_browser(browser: self, registration:, **overrides)
    browser.post "/user-api-key.json",
                 params: browser_approval_params(registration).merge(overrides),
                 as: :json
    expect(browser.response).to have_http_status(:ok)
  end

  def poll_android_browser(registration, browser: self)
    browser.post "/isbf/notifications/android-browser-links/poll.json",
                 params: {
                   android_device_token: registration.fetch("android_device_token"),
                 },
                 as: :json
    expect(browser.response).to have_http_status(:ok)
    browser.response.parsed_body
  end
end
