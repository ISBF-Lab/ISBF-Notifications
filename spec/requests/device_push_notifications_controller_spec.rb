# frozen_string_literal: true

RSpec.describe NotificationsController do
  fab!(:recipient, :user)
  fab!(:other_user, :user)
  fab!(:topic, :topic_with_op)

  describe "#index" do
    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.allow_user_locale = true
      recipient.update!(locale: "zh_CN")
      sign_in(recipient)
    end

    it "adds device metadata only when the direct client explicitly requests it" do
      notification =
        Fabricate(
          :notification,
          user: recipient,
          topic:,
          notification_type: Notification.types[:replied],
          data: { topic_title: topic.title, excerpt: topic.first_post.raw }.to_json,
        )
      get "/notifications.json", params: { silent: true }
      expect(response).to have_http_status(:ok)
      native = response.parsed_body
      expect(native["notifications"].first).not_to have_key("isbf_device_push")

      get "/notifications.json", params: { silent: true, device_push: true }
      expect(response).to have_http_status(:ok)
      enhanced = response.parsed_body
      expect(enhanced["notifications"].first["isbf_device_push"]).to eq(
        "version" => 1,
        "enabled" => true,
        "title" => topic.title,
        "body" => "你收到一条新回复。",
      )
      expect(enhanced["notifications"].map { |notice| notice.except("isbf_device_push") }).to eq(
        native["notifications"],
      )
      expect(enhanced.except("notifications")).to eq(native.except("notifications"))
      expect(notification.reload.read).to eq(false)
    end

    it "reports disabled events without hiding or mutating the native notifications" do
      SiteSetting.isbf_device_push_replied = false
      notification =
        Fabricate(
          :notification,
          user: recipient,
          topic:,
          notification_type: Notification.types[:replied],
        )
      notification_state = notification.reload.attributes
      get "/notifications.json", params: { silent: true, device_push: true, limit: 60, offset: 0 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["notifications"]).to contain_exactly(
        include("id" => notification.id, "isbf_device_push" => include("enabled" => false)),
      )
      expect(notification.reload.attributes).to eq(notification_state)
    end

    it "targets the triggering reply for direct push while keeping the in-site unread destination" do
      SiteSetting.nested_replies_enabled = true
      parent = Fabricate(:post, topic:, user: recipient)
      earlier = Fabricate(:post, topic:, user: other_user, reply_to_post_number: parent.post_number)
      latest = Fabricate(:post, topic:, user: other_user, reply_to_post_number: parent.post_number)
      notification =
        PostAlerter.new.create_notification(recipient, Notification.types[:replied], latest)
      expect(notification.post_number).to eq(earlier.post_number)
      original_attributes = notification.reload.attributes

      get "/notifications.json", params: { silent: true }
      native = response.parsed_body
      expect(native["notifications"].first["post_number"]).to eq(earlier.post_number)

      get "/notifications.json", params: { silent: true, device_push: true }
      enhanced = response.parsed_body
      expect(enhanced["notifications"].first["post_number"]).to eq(latest.post_number)
      expect(enhanced["notifications"].first.except("post_number", "isbf_device_push")).to eq(
        native["notifications"].first.except("post_number"),
      )
      expect(enhanced.except("notifications")).to eq(native.except("notifications"))
      expect(notification.reload.attributes).to eq(original_attributes)
    end

    it "keeps the stored destination for missing, hidden or unrelated triggering posts" do
      hidden = Fabricate(:post, topic:, hidden: true)
      foreign = Fabricate(:post)
      [hidden.id, foreign.id, -1, nil].each do |post_id|
        notification =
          Fabricate(
            :notification,
            user: recipient,
            topic:,
            post_number: 1,
            notification_type: Notification.types[:replied],
            data: { original_post_id: post_id }.to_json,
          )
        get "/notifications.json", params: { silent: true, device_push: true }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["notifications"].first).to include(
          "id" => notification.id,
          "post_number" => 1,
        )
      end
    end

    it "preserves pagination and excludes another user's notifications" do
      notices =
        3.times.map do
          Fabricate(
            :notification,
            user: recipient,
            topic:,
            notification_type: Notification.types[:replied],
          )
        end
      Fabricate(:notification, user: other_user, topic:)
      get "/notifications.json", params: { silent: true, device_push: true, limit: 1, offset: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["notifications"].map { |notice| notice["id"] }).to eq(
        [notices[1].id],
      )
      expect(response.parsed_body["total_rows_notifications"]).to eq(3)
    end

    it "preserves the original contract while the plugin is disabled" do
      SiteSetting.isbf_notifications_enabled = false
      Fabricate(:notification, user: recipient, topic:)
      get "/notifications.json", params: { silent: true, device_push: true }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["notifications"].first).not_to have_key("isbf_device_push")
    end

    it "requires authentication for the direct-client metadata" do
      sign_out
      reset!
      get "/notifications.json", params: { silent: true, device_push: true }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
