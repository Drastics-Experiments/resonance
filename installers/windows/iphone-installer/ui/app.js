import {
  INSTALLATION_LEDGER_KEY,
  INSTALL_STEPS,
  checklistState,
  formatCompactDate,
  formatExpiry,
  normalizeError,
  parseInstallationLedger,
  railState,
  refreshSummary,
  refreshUrgency,
  serializeInstallationLedger,
  shortDeviceId,
  sortInstallationsByRefresh,
  upsertInstallation,
} from "./state.mjs";

const tauri = window.__TAURI__;
const invoke = tauri?.core?.invoke;
const listen = tauri?.event?.listen;
const emit = tauri?.event?.emit;

const state = {
  stage: "connect",
  devices: [],
  selectedDevice: null,
  installations: [],
  busy: false,
  lastError: null,
  installStep: null,
  failedStep: null,
};

const elements = {};

function $(selector) {
  return document.querySelector(selector);
}

function all(selector) {
  return [...document.querySelectorAll(selector)];
}

function setBusy(busy, label) {
  state.busy = busy;
  all("main button, main input").forEach((element) => {
    if (element.id !== "copy-details") element.disabled = busy;
  });
  if (label) showNotice(label, "working");
  render();
}

function showNotice(message, kind = "info") {
  elements.notice.hidden = false;
  elements.notice.dataset.kind = kind;
  elements.notice.textContent = message;
}

function clearNotice() {
  elements.notice.hidden = true;
  elements.notice.textContent = "";
  delete elements.notice.dataset.kind;
}

function fail(error, fallback) {
  const normalized = normalizeError(error);
  state.lastError = normalized;
  showNotice(fallback ? `${fallback} ${normalized.message}` : normalized.message, "error");
  elements.copyDetails.hidden = false;
}

function setStage(stage) {
  state.stage = stage;
  clearNotice();
  all("[data-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.panel !== stage;
  });
  render();
}

function renderRail() {
  for (const item of railState(state.stage)) {
    const step = $(`[data-rail="${item.id}"]`);
    step.classList.toggle("is-current", item.current);
    step.classList.toggle("is-complete", item.complete);
  }
}

function renderDevices() {
  if (!state.devices.length) {
    elements.deviceList.innerHTML = `
      <div class="empty-state">
        <span class="device-glyph" aria-hidden="true"></span>
        <strong>No iPhone connected</strong>
        <p>Connect with USB, then select Find iPhone.</p>
      </div>`;
    return;
  }
  elements.deviceList.replaceChildren(
    ...state.devices.map((device) => {
      const installation = state.installations.find((record) => record.udid === device.udid);
      const installationNote = installation
        ? `<small class="installation-note">Resonance ${escapeHtml(installation.version)} · refresh ${escapeHtml(formatCompactDate(installation.expiresAt))}</small>`
        : "";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "device-card";
      button.classList.toggle("is-selected", state.selectedDevice?.udid === device.udid);
      button.innerHTML = `
        <span class="device-glyph" aria-hidden="true"></span>
        <span class="device-copy"><strong>${escapeHtml(device.name)}</strong><small>iOS ${escapeHtml(device.version)} · ${escapeHtml(device.connectionType)}</small>${installationNote}</span>
        <span class="selection-dot" aria-hidden="true"></span>`;
      button.addEventListener("click", () => selectDevice(device));
      return button;
    }),
  );
}

function renderInstallations() {
  elements.installationCount.textContent = state.installations.length
    ? `${state.installations.length} phone${state.installations.length === 1 ? "" : "s"}`
    : "";
  if (!state.installations.length) {
    const empty = document.createElement("div");
    empty.className = "installation-empty";
    empty.textContent = "No installations recorded yet.";
    elements.installationList.replaceChildren(empty);
    return;
  }

  elements.installationList.replaceChildren(
    ...sortInstallationsByRefresh(state.installations).map((record) => {
      const urgency = refreshUrgency(record.expiresAt);
      const row = document.createElement("div");
      row.className = "installation-row";
      row.title = `Installed ${formatCompactDate(record.installedAt)}`;

      const device = document.createElement("div");
      device.className = "installation-device";
      const name = document.createElement("strong");
      name.textContent = record.name;
      const identifier = document.createElement("small");
      identifier.textContent = `ID ${shortDeviceId(record.udid)}`;
      device.append(name, identifier);

      const version = document.createElement("span");
      version.className = "installation-version";
      version.textContent = `v${record.version}`;

      const refresh = document.createElement("span");
      refresh.className = "refresh-status";
      refresh.dataset.urgency = urgency;
      refresh.textContent = `${urgency === "expired" ? "Expired" : urgency === "due" ? "Due" : "Refresh"} ${formatCompactDate(record.expiresAt)}`;
      row.append(device, version, refresh);
      return row;
    }),
  );
}

function renderChecklist() {
  for (const item of checklistState(state.installStep, state.failedStep)) {
    const row = $(`[data-install-step="${item.id}"]`);
    row.dataset.state = item.state;
  }
}

function render() {
  renderRail();
  renderInstallations();
  renderDevices();
  renderChecklist();
  elements.continueDevice.disabled = state.busy || !state.selectedDevice;
  elements.findDevice.disabled = state.busy;
  if (state.selectedDevice) elements.summaryDevice.textContent = state.selectedDevice.name;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function findDevices() {
  if (!invoke) return fail("The native installer backend is unavailable.");
  setBusy(true, "Looking for connected iPhones…");
  try {
    const results = await invoke("list_devices");
    state.devices = results.filter((item) => !item.error).map((item) => item.device);
    state.selectedDevice = state.devices.length === 1 ? state.devices[0] : null;
    if (state.selectedDevice) await invoke("select_device", { device: state.selectedDevice });
    const urgentDevices = state.devices.filter((device) => {
      const installation = state.installations.find((record) => record.udid === device.udid);
      return installation && refreshUrgency(installation.expiresAt) !== "healthy";
    });
    if (urgentDevices.length) {
      showNotice(
        `${urgentDevices.length} connected iPhone${urgentDevices.length === 1 ? " needs" : "s need"} a Resonance refresh.`,
        "warning",
      );
    } else if (state.devices.length) {
      showNotice(`${state.devices.length} iPhone${state.devices.length === 1 ? "" : "s"} found.`, "success");
    } else {
      showNotice("No iPhone found. Unlock it, reconnect USB, and tap Trust This Computer.", "warning");
    }
  } catch (error) {
    fail(error, "Could not search for iPhones.");
  } finally {
    setBusy(false);
  }
}

async function selectDevice(device) {
  setBusy(true, `Connecting to ${device.name}…`);
  try {
    await invoke("select_device", { device });
    state.selectedDevice = device;
    showNotice(`${device.name} is ready.`, "success");
  } catch (error) {
    fail(error, "Could not use this iPhone.");
  } finally {
    setBusy(false);
  }
}

async function signIn(event) {
  event.preventDefault();
  const email = elements.email.value.trim();
  const password = elements.password.value;
  if (!email || !password) return;
  setBusy(true, "Signing in securely with Apple…");
  try {
    await invoke("login_new", {
      email,
      password,
    });
    elements.password.value = "";
    setStage("install");
  } catch (error) {
    elements.password.value = "";
    fail(error, "Apple sign-in failed.");
  } finally {
    setBusy(false);
  }
}

async function installResonance() {
  state.installStep = "verify";
  state.failedStep = null;
  setBusy(true, "Retrieving the latest Resonance release from GitHub…");
  try {
    const result = await invoke("install_resonance");
    state.installStep = "done";
    let trackingSaved = true;
    try {
      state.installations = upsertInstallation(state.installations, {
        udid: result.deviceUdid,
        name: result.deviceName,
        version: result.version,
        installedAt: result.installedAt,
        expiresAt: result.expiresAt,
      });
      localStorage.setItem(
        INSTALLATION_LEDGER_KEY,
        serializeInstallationLedger(state.installations),
      );
    } catch {
      trackingSaved = false;
    }
    elements.expiryDate.textContent = formatExpiry(result.expiresAt);
    elements.installedVersion.textContent = `Resonance ${result.version}`;
    setStage("success");
    if (!trackingSaved) {
      showNotice("Resonance was installed, but this phone's refresh record could not be saved.", "warning");
    }
  } catch (error) {
    state.failedStep = state.installStep || "verify";
    fail(error, "Installation failed.");
  } finally {
    setBusy(false);
  }
}

async function bindNativeEvents() {
  if (!listen) return;
  await listen("2fa-required", () => {
    elements.twoFactorCode.value = "";
    elements.twoFactorDialog.showModal();
    elements.twoFactorCode.focus();
  });
  await listen("max-certs-reached", (event) => {
    elements.certificateList.replaceChildren(
      ...event.payload.map((certificate, index) => {
        const label = document.createElement("label");
        label.className = "certificate-row";
        label.innerHTML = `<input type="checkbox" value="${escapeHtml(certificate.serialNumber || "")}" ${index === 0 ? "checked" : ""} /><span><strong>${escapeHtml(certificate.name || "Development certificate")}</strong><small>${escapeHtml(certificate.machineName || "Unknown device")}</small></span>`;
        return label;
      }),
    );
    elements.certificateDialog.showModal();
  });
  await listen("install-status", (event) => {
    if (INSTALL_STEPS.includes(event.payload.step)) state.installStep = event.payload.step;
    if (event.payload.message) showNotice(event.payload.message, "working");
    renderChecklist();
  });
}

async function initialize() {
  Object.assign(elements, {
    notice: $("#notice"),
    installationList: $("#installation-list"),
    installationCount: $("#installation-count"),
    deviceList: $("#device-list"),
    findDevice: $("#find-device"),
    continueDevice: $("#continue-device"),
    accountForm: $("#account-form"),
    email: $("#apple-email"),
    password: $("#apple-password"),
    signIn: $("#sign-in"),
    summaryDevice: $("#summary-device"),
    installButton: $("#install-button"),
    expiryDate: $("#expiry-date"),
    installedVersion: $("#installed-version"),
    refreshNow: $("#refresh-now"),
    doneButton: $("#done-button"),
    copyDetails: $("#copy-details"),
    twoFactorDialog: $("#two-factor-dialog"),
    twoFactorForm: $("#two-factor-form"),
    twoFactorCode: $("#two-factor-code"),
    certificateDialog: $("#certificate-dialog"),
    certificateForm: $("#certificate-form"),
    certificateList: $("#certificate-list"),
  });

  elements.findDevice.addEventListener("click", findDevices);
  elements.continueDevice.addEventListener("click", () => setStage("account"));
  elements.accountForm.addEventListener("submit", signIn);
  elements.installButton.addEventListener("click", installResonance);
  elements.refreshNow.addEventListener("click", () => setStage("account"));
  elements.doneButton.addEventListener("click", () => window.close());
  all("[data-back]").forEach((button) => button.addEventListener("click", () => setStage(button.dataset.back)));
  elements.copyDetails.addEventListener("click", async () => {
    if (state.lastError) await navigator.clipboard.writeText(`${state.lastError.type}: ${state.lastError.message}`);
  });
  elements.twoFactorForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const code = elements.twoFactorCode.value.trim();
    if (!/^\d{6}$/.test(code)) return;
    elements.twoFactorDialog.close();
    await emit("2fa-received", code);
  });
  elements.certificateForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const serials = [...elements.certificateList.querySelectorAll("input:checked")].map((input) => input.value);
    elements.certificateDialog.close();
    await emit("max-certs-response", serials.length ? serials : null);
  });
  $("#cancel-certificate").addEventListener("click", async () => {
    elements.certificateDialog.close();
    await emit("max-certs-response", null);
  });

  await bindNativeEvents();

  state.installations = parseInstallationLedger(localStorage.getItem(INSTALLATION_LEDGER_KEY));
  localStorage.removeItem("resonance-last-expiry");
  const summary = refreshSummary(state.installations);
  if (summary.expired) {
    showNotice(
      `${summary.expired} Resonance installation${summary.expired === 1 ? " has" : "s have"} expired. Connect ${summary.expired === 1 ? "that iPhone" : "those iPhones"} to refresh ${summary.expired === 1 ? "it" : "them"}.`,
      "warning",
    );
  } else if (summary.due) {
    showNotice(
      `${summary.due} Resonance installation${summary.due === 1 ? " needs" : "s need"} a refresh within 48 hours.`,
      "warning",
    );
  }
  render();
}

if (typeof document !== "undefined") initialize();
