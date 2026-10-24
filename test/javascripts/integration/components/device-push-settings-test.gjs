import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import DevicePushSettings from "discourse/plugins/isbf-notifications/discourse/components/device-push-settings";

const DEFAULTS = {
  liked: false,
  replied: true,
  mentioned: true,
  following: true,
  private_message: true,
  chat_message: true,
  chat_mention: true,
  topic_reminder: false,
  scheduled_event: true,
  calendar_changed: false,
};

module("Integration | Component | DevicePushSettings", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.currentUser.set("admin", true);
    pretender.get("/admin/config/site_settings.json", (request) =>
      response({
        site_settings:
          request.queryParams.filter_area === "notifications"
            ? [
                {
                  setting: "notification_consolidation_threshold",
                  humanized_name: "Notification consolidation threshold",
                  description:
                    "The number of likes before consolidating notices",
                  keywords: [],
                  default: "3",
                  value: "3",
                  category: "notifications",
                  type: "integer",
                },
              ]
            : Object.entries(DEFAULTS).map(([name, value]) => ({
                setting: `isbf_device_push_${name}`,
                value,
              })),
      })
    );
  });

  test("shows the ten grouped switches and uses server values", async function (assert) {
    await render(<template><DevicePushSettings /></template>);

    assert
      .dom(".isbf-device-push-settings__group")
      .exists({ count: 3 }, "related events share the accepted card layout");
    assert
      .dom("[role='switch']")
      .exists({ count: 10 }, "one shared set of event controls is displayed");
    assert
      .dom("[role='switch'][aria-label]")
      .exists({ count: 10 }, "every switch has an accessible name");
    assert
      .dom("[role='switch'][aria-label='Received likes']")
      .exists("the accessible name matches the visible event label");
    assert
      .dom("[role='switch'][aria-checked='true']")
      .exists({ count: 7 }, "server defaults are respected");
    assert
      .dom("button[type='submit']")
      .isDisabled("unchanged settings cannot be resubmitted");
    assert
      .dom(".isbf-device-push-settings")
      .includesText("In-site notifications and email", "the scope is clear");
    assert
      .dom(".isbf-device-push-settings")
      .doesNotIncludeText("review-only", "review-only notes are absent");
  });

  test("saves changed switches together and preserves drafts across the message preview", async function (assert) {
    const requests = [];
    pretender.put("/admin/site_settings/bulk_update", (request) => {
      requests.push(new URLSearchParams(request.requestBody));
      return response(204);
    });
    await render(<template><DevicePushSettings /></template>);

    await formKit().field("isbf_device_push_liked").toggle();
    await formKit().field("isbf_device_push_replied").toggle();
    assert.strictEqual(
      requests.length,
      0,
      "draft toggles do not write settings"
    );
    await click("[data-push-tab='copy']");
    assert
      .dom(".isbf-device-push-settings__copy")
      .exists(
        { count: 10 },
        "all configured event groups have message previews"
      );
    assert
      .dom(".isbf-device-push-settings")
      .includesText(
        "Your post received a reaction.",
        "reactions retain accurate wording within the reply switch"
      );
    await click("[data-push-tab='events']");
    await formKit().submit();

    assert.strictEqual(
      requests.length,
      1,
      "saving uses one native settings request"
    );
    assert.strictEqual(
      requests[0].get("settings[isbf_device_push_liked][value]"),
      "true",
      "likes are enabled"
    );
    assert.strictEqual(
      requests[0].get("settings[isbf_device_push_replied][value]"),
      "false",
      "the reply group is disabled"
    );
    assert.strictEqual(
      [...requests[0].keys()].length,
      2,
      "unchanged settings are omitted"
    );
    assert
      .dom("button[type='submit']")
      .isDisabled("successful save commits the form");
    assert
      .dom(".form-kit__alert")
      .includesText(
        "Settings saved.",
        "confirmation stays inside the developer page"
      );
  });

  test("discards edits to the last saved server values", async function (assert) {
    await render(<template><DevicePushSettings /></template>);
    await formKit().field("isbf_device_push_liked").toggle();
    await click(".form-kit__actions button:not([type='submit'])");
    assert
      .dom("[role='switch'][aria-checked='true']")
      .exists({ count: 7 }, "discard restores the loaded values");
    assert
      .dom("button[type='submit']")
      .isDisabled("discard clears the dirty state");
  });

  test("keeps existing filtered settings links on their native settings tab", async function (assert) {
    const outletArgs = {
      controller: {
        filter: "notification_consolidation_threshold",
        adminSettingsFilterChangedCallback() {},
      },
    };
    await render(
      <template><DevicePushSettings @outletArgs={{outletArgs}} /></template>
    );

    assert
      .dom("[data-push-tab='other']")
      .hasAttribute(
        "aria-current",
        "page",
        "the existing link selects its settings tab"
      );
    assert
      .dom("#setting-filter")
      .hasValue(
        "notification_consolidation_threshold",
        "the original filter is retained"
      );
    assert
      .dom(".setting-label")
      .includesText(
        "Notification consolidation threshold",
        "the requested native setting is displayed"
      );
  });

  test("keeps developer settings unavailable to moderators", async function (assert) {
    this.currentUser.setProperties({ admin: false, moderator: true });
    let requests = 0;
    pretender.get("/admin/config/site_settings.json", () => {
      requests++;
      return response(403);
    });
    await render(<template><DevicePushSettings /></template>);
    assert
      .dom(".isbf-device-push-settings")
      .doesNotExist("only developers can configure device pushes");
    assert.strictEqual(
      requests,
      0,
      "the hidden page does not request restricted settings"
    );
  });
});
