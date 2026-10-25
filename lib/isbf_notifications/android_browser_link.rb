# frozen_string_literal: true

module IsbfNotifications
  module AndroidBrowserLink
    STORE = "isbf-android-browser-links"
    COOKIE = "isbf_android_browser_link"
    CLIENT_PREFIX = "isbf-android-browser-"
    SCOPES = %w[notifications session_info].freeze
    TOKEN_PATTERN = /\A[a-f0-9]{64}\z/
    NONCE_PATTERN = /\A[a-f0-9]{32}\z/
    REGISTRATION_TTL = 10.minutes
    LINK_TTL = 90.days

    def self.allowed_user?(user)
      SiteSetting.isbf_notifications_enabled && user && user.active? && !user.suspended? &&
        !user.is_impersonating &&
        (user.staff? || user.in_any_groups?(SiteSetting.user_api_key_allowed_groups_map)) &&
        UserApiKey.allowed_scopes.superset?(Set.new(SCOPES))
    end

    class Registration
      attr_reader :token, :data

      def self.redis_key(key)
        "#{STORE}:pending:#{key}"
      end

      def self.for_client(client_id)
        digest = Discourse.redis.get(redis_key(client_id))
        from_digest(digest) if digest
      end

      def self.from_digest(digest)
        serialized = Discourse.redis.get(redis_key(digest))
        new(nil, JSON.parse(serialized)) if serialized
      end

      def initialize(token, data)
        @token = token
        @data = data.with_indifferent_access
      end

      def self.prepare(public_key:, nonce:)
        token = SecureRandom.hex(32)
        new(
          token,
          {
            digest: ApiKey.hash_key(token),
            client_id: "#{CLIENT_PREFIX}#{SecureRandom.uuid}",
            application_name: I18n.t("isbf_notifications.android_browser_link.application_name"),
            public_key: public_key,
            nonce: nonce,
            expires_at: REGISTRATION_TTL.from_now.to_i,
          },
        )
      end

      def save!
        Discourse.redis.setex(self.class.redis_key(data[:digest]), REGISTRATION_TTL, data.to_json)
        Discourse.redis.setex(
          self.class.redis_key(data[:client_id]),
          REGISTRATION_TTL,
          data[:digest],
        )
      end

      def remove!
        Discourse.redis.del(
          self.class.redis_key(data[:digest]),
          self.class.redis_key(data[:client_id]),
        )
      end

      def matches?(params)
        data[:expires_at] > Time.now.to_i && params[:nonce] == data[:nonce] &&
          params[:application_name].to_s == data[:application_name] &&
          params[:public_key].to_s == data[:public_key] && params[:padding] == "oaep" &&
          params[:push_url].blank? && params[:auth_redirect].blank? &&
          params[:scopes].to_s.split(",").sort == SCOPES.sort
      end

      def verification_url
        query = {
          client_id: data[:client_id],
          public_key: data[:public_key],
          nonce: data[:nonce],
          scopes: SCOPES.join(","),
          padding: "oaep",
          application_name: data[:application_name],
        }
        "#{Discourse.base_url}/user-api-key/new?#{query.to_query}"
      end
    end

    class Device
      attr_reader :digest, :data

      def self.find(digest)
        return if !TOKEN_PATTERN.match?(digest.to_s)
        data = PluginStore.get(STORE, digest)
        new(digest, data) if data
      end

      def self.from_token(token)
        find(ApiKey.hash_key(token))
      end

      def initialize(digest, data)
        @digest = digest
        @data = data.with_indifferent_access
      end

      def expired?
        data[:expires_at].to_i <= Time.now.to_i
      end

      def following?
        !expired? && %w[active signed_out].include?(data[:status])
      end

      def client
        @client ||= UserApiKeyClient.find_by(client_id: data[:client_id])
      end

      def save!
        row = PluginStoreRow.find_or_initialize_by(plugin_name: STORE, key: digest)
        row.assign_attributes(type_name: "JSON", value: data.to_json)
        row.save!
      end

      def key_valid?
        UserApiKey.active.where(id: data[:key_id], user_id: data[:user_id]).exists?
      end

      def session_valid?
        UserAuthToken
          .unexpired
          .where(id: data[:auth_token_id], user_id: data[:user_id], impersonated_user_id: nil)
          .exists? && AndroidBrowserLink.allowed_user?(User.find_by(id: data[:user_id]))
      end

      def revoke_keys!
        client&.keys&.active&.update_all(revoked_at: Time.zone.now)
      end

      def seal(payload)
        Base64.strict_encode64(
          UserApiKey::DeviceAuth::Crypto.encrypt!(
            OpenSSL::PKey::RSA.new(data[:public_key]),
            payload.merge(nonce: data[:nonce]).to_json,
            padding: "oaep",
          ),
        )
      end

      def synchronize!(user, auth_token_id: nil)
        user = nil unless AndroidBrowserLink.allowed_user?(user)
        mutate! do
          return unless following?
          if data[:status] == "active" && !key_valid?
            data.merge!(
              status: "revoked",
              revision: data[:revision] + 1,
              user_id: nil,
              key_id: nil,
              payload: seal(paused: true),
            )
            next
          end
          if data[:user_id] == user&.id && (user ? key_valid? : data[:status] == "signed_out")
            return if data[:auth_token_id] == auth_token_id
            data[:auth_token_id] = auth_token_id
            next
          end

          revoke_keys!
          data[:revision] += 1
          if user
            key =
              client.keys.create!(
                user: user,
                expires_at: Time.at(data[:expires_at]),
                scopes: SCOPES.map { |scope| UserApiKeyScope.new(name: scope) },
              )
            data.merge!(
              status: "active",
              user_id: user.id,
              auth_token_id: auth_token_id,
              key_id: key.id,
              payload: seal(key: key.key),
              notification_cursor: Notification.where(user_id: user.id).maximum(:id) || 0,
            )
          else
            data.merge!(
              status: "signed_out",
              user_id: nil,
              auth_token_id: nil,
              key_id: nil,
              payload: seal(paused: true),
            )
          end
        end
      end

      def disconnect!
        mutate! do
          return if data[:status] == "revoked"
          revoke_keys!
          data.merge!(
            status: "revoked",
            revision: data[:revision] + 1,
            user_id: nil,
            key_id: nil,
            payload: seal(paused: true),
          )
        end
      end

      def invalidate_revoked_grant!
        mutate! do
          return unless data[:status] == "active" && !key_valid?
          data.merge!(
            status: "revoked",
            revision: data[:revision] + 1,
            user_id: nil,
            key_id: nil,
            payload: seal(paused: true),
          )
        end
      end

      def snapshot
        {
          version: 1,
          status: expired? ? "expired" : data[:status],
          client_id: data[:client_id],
          revision: data[:revision],
          notification_cursor: data[:notification_cursor] || 0,
          payload: data[:payload],
        }
      end

      private

      def mutate!
        DistributedMutex.synchronize("#{STORE}:#{digest}") do
          ActiveRecord::Base.transaction do
            @data = PluginStore.get(STORE, digest)&.with_indifferent_access
            raise Discourse::NotFound if @data.blank?
            yield
            save!
          end
        end
      end
    end
  end
end
