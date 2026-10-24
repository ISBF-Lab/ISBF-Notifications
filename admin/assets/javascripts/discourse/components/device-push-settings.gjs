import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminAreaSettings from "discourse/admin/components/admin-area-settings";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq, not } from "discourse/truth-helpers";
import DBreadcrumbsItem from "discourse/ui-kit/d-breadcrumbs-item";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DPageHeader from "discourse/ui-kit/d-page-header";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import { i18n } from "discourse-i18n";

const PREFIX = "isbf_device_push_";
const GROUPS = {
  posts: ["liked", "replied", "mentioned", "following"],
  messages: ["private_message", "chat_message", "chat_mention"],
  schedule: ["topic_reminder", "scheduled_event", "calendar_changed"],
};
const COPIES = {
  liked: ["liked"],
  replied: ["replied", "reaction"],
  mentioned: ["mentioned", "group_mentioned"],
  following: ["following"],
  private_message: ["private_message"],
  chat_message: ["chat_message"],
  chat_mention: ["chat_mention"],
  topic_reminder: ["topic_reminder"],
  scheduled_event: ["event_before", "event_ongoing", "event_after"],
  calendar_changed: ["calendar_changed", "calendar_cancelled"],
};

export default class DevicePushSettings extends Component {
  @service a11y;
  @service currentUser;

  @tracked error = false;
  @tracked formApi;
  @tracked loading = true;
  @tracked saved = false;
  @tracked
  tab = this.args.outletArgs?.controller?.filter ? "other_settings" : "events";
  @tracked values;

  constructor() {
    super(...arguments);
    if (this.currentUser.admin) {
      this.loadSettings();
    } else {
      this.loading = false;
    }
  }

  get groups() {
    return Object.entries(GROUPS).map(([name, events]) => ({
      heading: `isbf_notifications.push_settings.groups.${name}`,
      fields: events.map((event) => ({
        name: `${PREFIX}${event}`,
        title: i18n(`isbf_notifications.push_settings.events.${event}`),
        description: i18n(
          `isbf_notifications.push_settings.descriptions.${event}`
        ),
      })),
    }));
  }

  get copies() {
    return Object.entries(COPIES).map(([event, variants]) => ({
      heading: `isbf_notifications.push_settings.events.${event}`,
      title: i18n(
        `isbf_notifications.push_settings.titles.${
          event.startsWith("chat_")
            ? "chat"
            : event === "scheduled_event" || event === "calendar_changed"
              ? "event"
              : event === "private_message"
                ? "private_message"
                : "post"
        }`
      ),
      variants: variants.map((variant) => ({
        key: variant,
        body: i18n(`isbf_notifications.push_settings.bodies.${variant}`),
      })),
    }));
  }

  get disabled() {
    return !this.formApi?.isDirty;
  }

  get showSaved() {
    return this.saved && this.disabled;
  }

  get tabs() {
    return ["events", "copy", "other_settings"].map((name) => ({
      active: name === this.tab,
      name,
      label: `isbf_notifications.push_settings.tabs.${name}`,
    }));
  }

  @action
  async loadSettings() {
    this.loading = true;
    this.error = false;
    try {
      const result = await ajax("/admin/config/site_settings.json", {
        data: { filter_area: "device_push_events" },
      });
      if (!this.isDestroying) {
        this.values = Object.fromEntries(
          result.site_settings.map((setting) => [
            setting.setting,
            setting.value === true || setting.value === "true",
          ])
        );
      }
    } catch (error) {
      if (!this.isDestroying) {
        this.error = true;
        popupAjaxError(error);
      }
    } finally {
      if (!this.isDestroying) {
        this.loading = false;
      }
    }
  }

  @action
  registerForm(api) {
    this.formApi = api;
  }

  @action
  reset() {
    this.formApi.reset();
    this.saved = false;
  }

  @action
  async save(data) {
    const settings = {};
    for (const event of Object.keys(COPIES)) {
      const name = `${PREFIX}${event}`;
      if (data[name] !== this.values[name]) {
        settings[name] = { value: data[name] };
      }
    }
    if (!Object.keys(settings).length) {
      return;
    }
    try {
      await ajax("/admin/site_settings/bulk_update", {
        type: "PUT",
        data: { settings },
      });
      this.formApi.commit();
      this.values = { ...data };
      this.saved = true;
      this.a11y.announce(
        i18n("isbf_notifications.push_settings.saved"),
        "polite"
      );
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  selectTab(tab) {
    this.tab = tab;
  }

  <template>
    {{#if this.currentUser.admin}}
      <DPageHeader
        class="isbf-device-push-settings__header"
        @descriptionLabel={{i18n
          "isbf_notifications.push_settings.description"
        }}
        @titleLabel={{i18n "admin.config.notifications.title"}}
      >
        <:breadcrumbs>
          <DBreadcrumbsItem @label={{i18n "admin_title"}} @path="/admin" />
          <DBreadcrumbsItem
            @label={{i18n "admin.config.notifications.title"}}
            @path="/admin/config/notifications"
          />
        </:breadcrumbs>
        <:tabs>
          {{#each this.tabs as |tab|}}
            <li class={{dConcatClass (if tab.active "active")}}>
              <button
                aria-current={{if tab.active "page"}}
                data-push-tab={{tab.name}}
                type="button"
                {{on "click" (fn this.selectTab tab.name)}}
              >{{i18n tab.label}}</button>
            </li>
          {{/each}}
        </:tabs>
      </DPageHeader>

      <div
        class="admin-config-page__main-area isbf-device-push-settings"
        ...attributes
      >
        <section hidden={{not (eq this.tab "events")}}>
          <DPageSubheader
            @descriptionLabel={{i18n "isbf_notifications.push_settings.scope"}}
            @titleLabel={{i18n "isbf_notifications.push_settings.title"}}
          />
          <p>{{i18n "isbf_notifications.push_settings.boundary"}}</p>
          <DConditionalLoadingSpinner @condition={{this.loading}}>
            {{#if this.error}}
              <DButton @action={{this.loadSettings}} @label="retry" />
            {{else if this.values}}
              <Form
                @commitOnSubmit={{false}}
                @data={{this.values}}
                @onRegisterApi={{this.registerForm}}
                @onSubmit={{this.save}}
                as |form|
              >
                {{#each this.groups as |group|}}
                  <AdminConfigAreaCard
                    class="isbf-device-push-settings__group"
                    @heading={{group.heading}}
                  >
                    <:content>
                      {{#each group.fields as |field|}}
                        <form.Field
                          @description={{field.description}}
                          @name={{field.name}}
                          @title={{field.title}}
                          @type="toggle"
                          as |control|
                        >
                          <DToggleSwitch
                            aria-describedby={{control.descriptionId}}
                            aria-label={{field.title}}
                            class="form-kit__control-toggle"
                            disabled={{control.disabled}}
                            id={{control.id}}
                            @state={{control.value}}
                            {{on "click" (fn control.set (not control.value))}}
                          />
                        </form.Field>
                      {{/each}}
                    </:content>
                  </AdminConfigAreaCard>
                {{/each}}
                {{#if this.showSaved}}
                  <form.Alert @type="success">{{i18n
                      "isbf_notifications.push_settings.saved"
                    }}</form.Alert>
                {{/if}}
                <form.Actions>
                  <form.Submit
                    @disabled={{this.disabled}}
                    @label="isbf_notifications.push_settings.save"
                  />
                  <form.Button
                    @action={{this.reset}}
                    @disabled={{this.disabled}}
                    @label="isbf_notifications.push_settings.cancel"
                  />
                </form.Actions>
              </Form>
            {{/if}}
          </DConditionalLoadingSpinner>
        </section>

        <section hidden={{not (eq this.tab "copy")}}>
          <DPageSubheader
            @descriptionLabel={{i18n
              "isbf_notifications.push_settings.copy_description"
            }}
            @titleLabel={{i18n "isbf_notifications.push_settings.tabs.copy"}}
          />
          {{#each this.copies as |copy|}}
            <AdminConfigAreaCard
              class="isbf-device-push-settings__copy"
              @heading={{copy.heading}}
            >
              <:content>
                <p><strong>{{i18n
                      "isbf_notifications.push_settings.subject"
                    }}</strong>
                  {{copy.title}}</p>
                {{#each copy.variants as |variant|}}
                  <p><strong>{{i18n
                        "isbf_notifications.push_settings.body"
                      }}</strong>
                    {{variant.body}}</p>
                {{/each}}
              </:content>
            </AdminConfigAreaCard>
          {{/each}}
        </section>

        {{#if (eq this.tab "other_settings")}}
          <AdminAreaSettings
            @adminSettingsFilterChangedCallback={{@outletArgs.controller.adminSettingsFilterChangedCallback}}
            @area="notifications"
            @filter={{@outletArgs.controller.filter}}
            @path="/admin/config/notifications"
            @showBreadcrumb={{false}}
          />
        {{/if}}
      </div>
    {{/if}}
  </template>
}
