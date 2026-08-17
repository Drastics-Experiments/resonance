import {
  accessibleNameCandidate,
  canRestoreFocus,
  isElementVisiblyInteractive,
  navigationCurrentValue,
} from "./ui-quality-core.js";

const CONTROL_WITH_FALLBACK_NAME = [
  "button[title]",
  "[role='button'][title]",
  "input[title]",
  "select[title]",
  "textarea[title]",
].join(",");
const DIALOG_FOCUS_TARGET = [
  "[autofocus]",
  "button:not([disabled])",
  "[href]",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",");
const stylesheetURL = new URL("./ui-quality.css", import.meta.url).href;
const dialogOpeners = new WeakMap();
const dialogOpenState = new WeakMap();
const queuedRoots = new Set();
let lastInvoker = null;
const DIALOG_INVOKER_WINDOW_MS = 1500;
let scanHandle = null;

function ensureQualityStylesheet() {
  if (document.querySelector("link[data-resonance-ui-quality]")) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = stylesheetURL;
  link.dataset.resonanceUiQuality = "";
  document.head.append(link);
}

function elementDescriptor(element) {
  const style = getComputedStyle(element);
  return {
    connected: element.isConnected,
    disabled: "disabled" in element && Boolean(element.disabled),
    hidden: element.hidden || style.display === "none" || style.visibility === "hidden",
    inert: element.closest("[inert]") !== null,
  };
}

function interactiveDescriptor(element) {
  return {
    hidden: element.hidden || element.closest("[hidden]") !== null,
    disabled: "disabled" in element && Boolean(element.disabled),
    tabIndex: element.tabIndex,
    ariaHidden: element.getAttribute("aria-hidden") === "true",
  };
}

function applyFallbackAccessibleName(control) {
  const candidate = accessibleNameCandidate({
    ariaLabel: control.getAttribute("aria-label"),
    labelledBy: control.getAttribute("aria-labelledby"),
    title: control.getAttribute("title"),
  });
  if (candidate) control.setAttribute("aria-label", candidate);
}

function syncNavigationState(root = document) {
  const navigationButtons = root instanceof Element && root.matches(".nav[data-section]")
    ? [root]
    : root.querySelectorAll?.(".nav[data-section]") || [];
  for (const button of navigationButtons) {
    const current = navigationCurrentValue(button.classList.contains("active"));
    if (current) button.setAttribute("aria-current", current);
    else button.removeAttribute("aria-current");
  }
}

function visibleDialogFocusTarget(dialog) {
  for (const candidate of dialog.querySelectorAll(DIALOG_FOCUS_TARGET)) {
    if (isElementVisiblyInteractive(interactiveDescriptor(candidate))) return candidate;
  }
  return null;
}

function rememberDialogOpener(dialog, opener) {
  if (opener instanceof HTMLElement && opener.isConnected && !dialog.contains(opener)) {
    dialogOpeners.set(dialog, opener);
  }
}

function handleDialogState(dialog) {
  const isOpen = dialog.open;
  const wasOpen = dialogOpenState.get(dialog) === true;
  if (isOpen === wasOpen) return;
  dialogOpenState.set(dialog, isOpen);

  if (isOpen) {
    const recentInvoker = lastInvoker && performance.now() - lastInvoker.timestamp <= DIALOG_INVOKER_WINDOW_MS
      ? lastInvoker.element
      : null;
    rememberDialogOpener(dialog, recentInvoker || document.activeElement);
    requestAnimationFrame(() => {
      if (!dialog.open || dialog.contains(document.activeElement)) return;
      visibleDialogFocusTarget(dialog)?.focus({ preventScroll: true });
    });
    return;
  }

  const opener = dialogOpeners.get(dialog);
  dialogOpeners.delete(dialog);
  const activeElement = document.activeElement;
  if (!(activeElement === document.body || activeElement === document.documentElement || dialog.contains(activeElement))) return;
  requestAnimationFrame(() => {
    if (opener instanceof HTMLElement && canRestoreFocus(elementDescriptor(opener))) {
      opener.focus({ preventScroll: true });
    }
  });
}

function enhanceSubtree(root) {
  if (!(root instanceof Document || root instanceof Element || root instanceof DocumentFragment)) return;
  if (root instanceof Element && root.matches(CONTROL_WITH_FALLBACK_NAME)) applyFallbackAccessibleName(root);
  for (const control of root.querySelectorAll?.(CONTROL_WITH_FALLBACK_NAME) || []) applyFallbackAccessibleName(control);
  syncNavigationState(root);

  const dialogs = root instanceof HTMLDialogElement
    ? [root]
    : root.querySelectorAll?.("dialog") || [];
  for (const dialog of dialogs) handleDialogState(dialog);
}

function runQueuedScans(deadline) {
  scanHandle = null;
  const hasTime = () => !deadline || deadline.didTimeout || deadline.timeRemaining() > 2;
  for (const root of queuedRoots) {
    queuedRoots.delete(root);
    enhanceSubtree(root);
    if (!hasTime()) break;
  }
  if (queuedRoots.size > 0) scheduleQueuedScan();
}

function scheduleQueuedScan() {
  if (scanHandle !== null) return;
  if (typeof requestIdleCallback === "function") {
    scanHandle = requestIdleCallback(runQueuedScans, { timeout: 120 });
  } else {
    scanHandle = setTimeout(() => runQueuedScans(null), 0);
  }
}

function queueSubtree(root) {
  if (!(root instanceof Element || root instanceof DocumentFragment || root instanceof Document)) return;
  queuedRoots.add(root);
  scheduleQueuedScan();
}

function captureInvoker(event) {
  const target = event.target instanceof Element
    ? event.target.closest("button, [role='button'], a[href], input, select, textarea, [tabindex]")
    : null;
  if (target instanceof HTMLElement) lastInvoker = { element: target, timestamp: performance.now() };

  if (!(target instanceof HTMLElement)) return;
  const controlledID = target.getAttribute("aria-controls");
  if (!controlledID) return;
  const controlled = document.getElementById(controlledID);
  if (controlled instanceof HTMLDialogElement) rememberDialogOpener(controlled, target);
}

function observeRenderer() {
  const observer = new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "childList") {
        for (const node of record.addedNodes) queueSubtree(node);
        continue;
      }
      const target = record.target;
      if (target instanceof HTMLDialogElement && record.attributeName === "open") {
        handleDialogState(target);
      } else if (target instanceof Element && target.matches(".nav[data-section]") && record.attributeName === "class") {
        syncNavigationState(target);
      } else if (target instanceof Element) {
        queueSubtree(target);
      }
    }
  });
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["open", "class", "title", "aria-label", "aria-labelledby", "disabled", "hidden"],
  });
}

ensureQualityStylesheet();
document.addEventListener("pointerdown", captureInvoker, true);
document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" || event.key === " ") captureInvoker(event);
}, true);
queueSubtree(document);
observeRenderer();
