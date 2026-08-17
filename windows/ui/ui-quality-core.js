const COLLAPSED_WHITESPACE = /\s+/g;

export function compactAccessibleText(value) {
  return typeof value === "string" ? value.replace(COLLAPSED_WHITESPACE, " ").trim() : "";
}

export function accessibleNameCandidate({ ariaLabel = "", labelledBy = "", title = "", text = "" } = {}) {
  if (compactAccessibleText(ariaLabel) || compactAccessibleText(labelledBy)) return "";
  return compactAccessibleText(title) || compactAccessibleText(text);
}

export function navigationCurrentValue(active) {
  return active ? "page" : null;
}

export function canRestoreFocus({ connected = false, disabled = false, hidden = false, inert = false } = {}) {
  return connected && !disabled && !hidden && !inert;
}

export function isElementVisiblyInteractive({ hidden = false, disabled = false, tabIndex = 0, ariaHidden = false } = {}) {
  return !hidden && !disabled && !ariaHidden && tabIndex >= 0;
}
