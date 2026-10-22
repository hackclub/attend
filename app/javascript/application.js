// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import { startToggleHidden } from "utils/toggle_hidden"
import { startConsoleConfirm } from "utils/console_confirm"
import { startTurboScriptNonce } from "utils/turbo_script_nonce"

startToggleHidden()
startConsoleConfirm()
startTurboScriptNonce()

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/service-worker", { scope: "/" })
}
