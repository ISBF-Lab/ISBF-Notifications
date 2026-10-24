import { apiInitializer } from "discourse/lib/api";
import DevicePushSettings from "../components/device-push-settings";

export default apiInitializer((api) => {
  const currentUser = api.getCurrentUser();
  const siteSettings = api.container.lookup("service:site-settings");
  if (currentUser?.admin && siteSettings.isbf_notifications_enabled) {
    api.renderInOutlet("admin-notification-settings", DevicePushSettings);
  }
});
