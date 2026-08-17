import test from "node:test";
import assert from "node:assert/strict";

import {
  accessibleNameCandidate,
  canRestoreFocus,
  compactAccessibleText,
  isElementVisiblyInteractive,
  navigationCurrentValue,
} from "../ui/ui-quality-core.js";

test("accessible names use explicit labels before title fallbacks", () => {
  assert.equal(compactAccessibleText("  Restart\n and   update  "), "Restart and update");
  assert.equal(accessibleNameCandidate({ title: "  Close  " }), "Close");
  assert.equal(accessibleNameCandidate({ ariaLabel: "Already named", title: "Ignore me" }), "");
  assert.equal(accessibleNameCandidate({ labelledBy: "dialog-title", title: "Ignore me" }), "");
});

test("navigation state exposes only the active destination", () => {
  assert.equal(navigationCurrentValue(true), "page");
  assert.equal(navigationCurrentValue(false), null);
});

test("focus restoration rejects stale or unavailable controls", () => {
  assert.equal(canRestoreFocus({ connected: true }), true);
  assert.equal(canRestoreFocus({ connected: false }), false);
  assert.equal(canRestoreFocus({ connected: true, disabled: true }), false);
  assert.equal(canRestoreFocus({ connected: true, hidden: true }), false);
  assert.equal(canRestoreFocus({ connected: true, inert: true }), false);
});

test("dialog focus candidates must remain keyboard reachable", () => {
  assert.equal(isElementVisiblyInteractive({ tabIndex: 0 }), true);
  assert.equal(isElementVisiblyInteractive({ tabIndex: -1 }), false);
  assert.equal(isElementVisiblyInteractive({ tabIndex: 0, hidden: true }), false);
  assert.equal(isElementVisiblyInteractive({ tabIndex: 0, ariaHidden: true }), false);
  assert.equal(isElementVisiblyInteractive({ tabIndex: 0, disabled: true }), false);
});
