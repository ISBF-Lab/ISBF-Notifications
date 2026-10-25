# frozen_string_literal: true

module IsbfNotifications::AndroidBrowserLink::Authorization
  def create
    client_id = params[:client_id].to_s
    return super unless client_id.start_with?(IsbfNotifications::AndroidBrowserLink::CLIENT_PREFIX)

    raise Discourse::InvalidAccess if !request.format.json? || is_api? || is_user_api?
    DistributedMutex.synchronize("android-browser-consent:#{client_id}") do
      registration = IsbfNotifications::AndroidBrowserLink::Registration.for_client(client_id)
      raise Discourse::InvalidAccess unless registration&.matches?(params)
      ActiveRecord::Base.transaction do
        super
        IsbfNotifications::AndroidBrowserLink::Complete.call(
          service_params.deep_merge(
            params: {
              payload: @payload,
            },
            options: {
              previous_browser_key:
                cookies.encrypted[IsbfNotifications::AndroidBrowserLink::COOKIE],
              auth_token_id: request.env[Auth::DefaultCurrentUserProvider::USER_TOKEN_KEY]&.id,
            },
          ),
        ) do
          on_success do |device:|
            cookies.encrypted[IsbfNotifications::AndroidBrowserLink::COOKIE] = {
              value: device.digest,
              httponly: true,
              secure: SiteSetting.force_https,
              same_site: :lax,
              expires: IsbfNotifications::AndroidBrowserLink::LINK_TTL.from_now,
            }
            response.body = { redirect_url: return_to_application }.to_json
          end
          on_failure { raise Discourse::InvalidAccess }
        end
      end
    end
  end

  private

  def return_to_application
    fallback = CGI.escape(Discourse.base_url)
    "intent://isbf-one.com/isbf/notifications/android-return#Intent;scheme=https;" \
      "package=com.isbf.one.twa;S.browser_fallback_url=#{fallback};end"
  end
end

module IsbfNotifications::AndroidBrowserLink::BrowserSession
  def set_auth_cookie!(unhashed_auth_token, user, cookie_jar)
    result = super
    synchronize_android_browser(user, cookie_jar)
    result
  end

  def log_off_user(session, cookie_jar, push_subscription: nil)
    result = super
    synchronize_android_browser(nil, cookie_jar)
    result
  end

  def refresh_session(user, session, cookie_jar)
    result = super
    synchronize_android_browser(nil, cookie_jar) unless user
    result
  end

  private

  def synchronize_android_browser(user, cookie_jar)
    return if cookie_jar[IsbfNotifications::AndroidBrowserLink::COOKIE].blank?
    browser_key = cookie_jar.encrypted[IsbfNotifications::AndroidBrowserLink::COOKIE]
    return if browser_key.blank?
    IsbfNotifications::AndroidBrowserLink::Synchronize.call(
      params: {
        browser_key: browser_key,
      },
      guardian: user ? user.guardian : Guardian.new,
      options: {
        auth_token_id: user ? @user_token&.id : nil,
      },
    )
  rescue StandardError => error
    begin
      IsbfNotifications::AndroidBrowserLink::Device.find(browser_key)&.synchronize!(nil)
    rescue StandardError
      nil
    end
    # Pairing must never interrupt the forum's own login or logout response.
    Rails.logger.warn("Android browser notification link failed (#{error.class.name})")
  end
end
