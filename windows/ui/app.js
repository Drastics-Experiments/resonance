import { createEmptyState, filterTracks, formatTime, mergeSyncedTracks, nextIndex, normalizeState, tracksForPlaylist } from "./core.js";

const api = window.likedSongs;
const audio = document.querySelector("#audio");
const content = document.querySelector("#content");
let state = createEmptyState();
let currentID = null;
let section = "library";
let selectedPlaylistID = null;
let libraryFilter = "all";
let serverToken = "";
let serverAdminToken = "";
let serverCatalog = [];
let selectedRemoteIDs = new Set();
let shuffle = false;
let repeat = false;
let history = [];
let navigationHistory = [{ section: "library", playlistID: null }];
let navigationIndex = 0;
let pendingPlaylistTrackID = null;

const $ = (selector) => document.querySelector(selector);
const shuffleIcon = `<svg class="shuffle-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h2.5a5 5 0 0 1 4 2l5 7a5 5 0 0 0 4 2H21"/><path d="m17 13 4 4-4 4"/><path d="M3 18h2.5a5 5 0 0 0 4-2l5-7a5 5 0 0 1 4-2H21"/><path d="m17 3 4 4-4 4"/></svg>`;
const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
const currentTrack = () => state.tracks.find((track) => track.id === currentID) || null;
const playlistTracks = () => selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : state.tracks;

async function persist() {
  normalizeState(state);
  await api.saveLibrary(state);
  renderSidebar();
}

function artwork(track) {
  return `<div class="row-art">${track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪"}</div>`;
}

function trackRow(track, index) {
  const liked = state.favorites.includes(track.id);
  return `<div class="track-row ${track.id === currentID ? "playing" : ""}" data-track="${track.id}">
    <span class="track-number">${track.id === currentID && !audio.paused ? "▥" : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / Audio</small></div>
    <span class="album">${escapeHTML(track.album)}</span><span class="track-time">${formatTime(track.duration)}</span>
    <button class="heart" data-favorite="${track.id}">${liked ? "♥" : "♡"}</button>
  </div>`;
}

function renderLibrary() {
  const tracks = filterTracks(playlistTracks(), $("#search").value, libraryFilter);
  const title = selectedPlaylistID ? state.playlists.find((item) => item.id === selectedPlaylistID)?.name || "Playlist" : "Library";
  content.innerHTML = `<div class="collection-scroll"><div class="hero"><div class="hero-art">≋</div><div><span class="eyebrow">${selectedPlaylistID ? "PLAYLIST" : "MUSIC LIBRARY"}</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions"><button class="primary" id="playCollection">${audio.paused ? "▶ Play" : "Ⅱ Pause"}</button><button class="round ${shuffle ? "active" : ""}" id="heroShuffle" title="Shuffle" aria-label="Shuffle">${shuffleIcon}</button><button class="secondary" id="importAudio">＋ Import audio</button></div></div></div>
    <div class="filters"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio">Audio</button></div>
    <div class="track-table"><div class="track-header"><span>#</span><span></span><span>Title</span><span>Album</span><span>Time</span><span></span></div>
    ${tracks.length ? tracks.map(trackRow).join("") : `<div class="empty"><b>${selectedPlaylistID ? "This playlist is empty" : "No songs yet"}</b><span>${selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server."}</span></div>`}</div></div>`;
  bindTrackRows();
  $("#importAudio").onclick = importAudio;
  $("#playCollection").onclick = () => currentTrack() ? toggle() : tracks[0] && play(tracks[0]);
  $("#heroShuffle").onclick = () => { shuffle = !shuffle; updateChrome(); render(); };
  document.querySelectorAll("[data-library-filter]").forEach((button) => button.onclick = () => {
    libraryFilter = button.dataset.libraryFilter;
    renderLibrary();
  });
}

function renderPlaylists() {
  content.innerHTML = `<div class="page"><span class="eyebrow">YOUR COLLECTIONS</span><h1>Playlists</h1><p>Organize your local music into collections.</p><button class="primary" id="pageNewPlaylist">＋ New Playlist</button><div class="playlist-grid">${state.playlists.map((playlist) => `<button class="playlist-card" data-open-playlist="${playlist.id}"><div class="playlist-art">${playlist.isSystem ? "♥" : "♪"}</div><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div><span>›</span></button>`).join("")}</div></div>`;
  $("#pageNewPlaylist").onclick = () => newPlaylist();
  document.querySelectorAll("[data-open-playlist]").forEach((button) => button.onclick = () => navigate("library", button.dataset.openPlaylist));
}

function renderStorage() {
  const total = state.tracks.reduce((sum, track) => sum + (track.size || 0), 0);
  content.innerHTML = `<div class="page"><span class="eyebrow">LOCAL FILES</span><h1>Song Storage</h1><p>${state.tracks.length} songs • ${(total / 1048576).toFixed(1)} MB tracked</p><button class="primary" id="storageImport">＋ Import audio</button><div class="storage-list">${state.tracks.map((track) => `<div><div>${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.filePath)}</small></span></div><button class="danger" data-delete="${track.id}">Delete</button></div>`).join("") || `<div class="empty"><b>No local files</b></div>`}</div></div>`;
  $("#storageImport").onclick = importAudio;
  document.querySelectorAll("[data-delete]").forEach((button) => button.onclick = async () => {
    const track = state.tracks.find((item) => item.id === button.dataset.delete);
    if (!track || !confirm(`Remove ${track.title} from this device?`)) return;
    await api.deleteAudio(track.filePath);
    state.tracks = state.tracks.filter((item) => item.id !== track.id);
    state.favorites = state.favorites.filter((id) => id !== track.id);
    state.playlists.forEach((playlist) => playlist.trackIDs = playlist.trackIDs.filter((id) => id !== track.id));
    if (currentID === track.id) { audio.pause(); currentID = null; }
    await persist(); render(); updateChrome();
  });
}

function renderServer() {
  content.innerHTML = `<div class="page server-page"><span class="eyebrow">REMOTE LIBRARY</span><h1>Music Server</h1><p>Select what to download, upload music, and monitor active transfers.</p><div class="server-card"><label><span>◎</span><input id="serverURL" value="${escapeHTML(state.serverURL)}" placeholder="https://music.unblocked.mov"></label><label><span>◆</span><input id="serverToken" type="password" value="${escapeHTML(serverToken)}" placeholder="Server access token"></label><label><span>◇</span><input id="serverAdminToken" type="password" value="${escapeHTML(serverAdminToken)}" placeholder="Server admin key"></label><div><button class="primary" id="refreshServer">Connect</button><button class="secondary" id="syncSelected">Download selected</button><button class="secondary" id="syncAll">Download all</button><button class="secondary" id="uploadServer">Upload songs</button></div><small id="serverStatus">Not connected</small><div class="transfer-grid"><div><b>Downloads</b><progress id="downloadProgress" max="1" value="0"></progress><small id="downloadDetail">Idle</small></div><div><b>Uploads</b><progress id="uploadProgress" max="1" value="0"></progress><small id="uploadDetail">Idle</small></div></div></div><div class="remote-heading"><strong>Server Catalog</strong><span id="remoteCount">${serverCatalog.length} songs</span></div><div id="remoteSongs" class="remote-list">${serverCatalog.length ? remoteRows() : `<div class="empty"><span>Connect to view hosted songs.</span></div>`}</div></div>`;
  $("#refreshServer").onclick = () => serverAction("catalog");
  $("#syncSelected").onclick = () => serverAction("selected");
  $("#syncAll").onclick = () => serverAction("all");
  $("#uploadServer").onclick = uploadServerSongs;
  $("#serverToken").onchange = saveServerForm;
  $("#serverAdminToken").onchange = saveServerForm;
  bindRemoteRows();
}

function remoteRows() {
  return serverCatalog.map((song) => `<div><button class="remote-check" data-select-remote="${song.id}">${selectedRemoteIDs.has(song.id) ? "●" : "○"}</button>${artwork(song)}<span><strong>${escapeHTML(song.title || song.name)}</strong><small>${escapeHTML(song.album || "Server Library")} • ${(song.size / 1048576).toFixed(1)} MB</small></span><b class="sync-state">${state.tracks.some((track) => track.remoteID === song.id) ? "✓ Synced" : "Available"}</b><button class="danger" data-delete-remote="${song.id}">Delete</button></div>`).join("");
}

function bindRemoteRows() {
  document.querySelectorAll("[data-select-remote]").forEach((button) => button.onclick = () => { selectedRemoteIDs.has(button.dataset.selectRemote) ? selectedRemoteIDs.delete(button.dataset.selectRemote) : selectedRemoteIDs.add(button.dataset.selectRemote); renderServer(); });
  document.querySelectorAll("[data-delete-remote]").forEach((button) => button.onclick = async () => {
    const song = serverCatalog.find((item) => item.id === button.dataset.deleteRemote);
    if (!song || !confirm(`Delete ${song.title || song.name} from the server?`)) return;
    await saveServerForm();
    await api.deleteServerSong({ baseURL: state.serverURL, adminToken: serverAdminToken, songID: song.id });
    await serverAction("catalog");
  });
}

async function saveServerForm() {
  state.serverURL = $("#serverURL")?.value.trim() || state.serverURL;
  serverToken = $("#serverToken")?.value || serverToken;
  serverAdminToken = $("#serverAdminToken")?.value || serverAdminToken;
  await api.saveServerCredentials({ clientToken: serverToken, adminToken: serverAdminToken });
  await persist();
}

function render() {
  if (section === "library") renderLibrary();
  else if (section === "playlists") renderPlaylists();
  else if (section === "storage") renderStorage();
  else renderServer();
  renderSidebar();
  renderQueue();
  $("#navBack").disabled = navigationIndex === 0;
  $("#navForward").disabled = navigationIndex + 1 >= navigationHistory.length;
}

function bindTrackRows() {
  document.querySelectorAll("[data-track]").forEach((row) => {
    row.onclick = (event) => {
      if (event.target.closest("button, select, input, a")) return;
      play(state.tracks.find((track) => track.id === row.dataset.track));
    };
    row.oncontextmenu = (event) => openTrackContextMenu(event, row.dataset.track);
  });
  document.querySelectorAll("[data-favorite]").forEach((button) => button.onclick = (event) => { event.stopPropagation(); toggleFavorite(button.dataset.favorite); });
}

function closeTrackContextMenu() {
  const menu = $("#trackContextMenu");
  menu.hidden = true;
  menu.innerHTML = "";
}

function openTrackContextMenu(event, trackID) {
  event.preventDefault();
  const menu = $("#trackContextMenu");
  const track = state.tracks.find((item) => item.id === trackID);
  if (!track) return;
  const playlists = state.playlists.filter((item) => !item.isSystem);
  menu.innerHTML = `<div class="context-heading"><small>ADD TO PLAYLIST</small><strong>${escapeHTML(track.title)}</strong></div>${playlists.length ? playlists.map((playlist) => {
    const added = playlist.trackIDs.includes(trackID);
    return `<button role="menuitem" data-context-playlist="${escapeHTML(playlist.id)}" ${added ? "disabled" : ""}><span>${added ? "✓" : "＋"}</span>${escapeHTML(playlist.name)}</button>`;
  }).join("") : `<div class="context-empty">No playlists yet</div>`}<button role="menuitem" data-context-new><span>＋</span>Create new playlist…</button>`;
  menu.hidden = false;
  menu.style.left = `${Math.max(8, Math.min(event.clientX, innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(event.clientY, innerHeight - menu.offsetHeight - 8))}px`;
  menu.querySelectorAll("[data-context-playlist]").forEach((button) => button.onclick = async () => {
    const playlist = state.playlists.find((item) => item.id === button.dataset.contextPlaylist);
    if (playlist && !playlist.trackIDs.includes(trackID)) playlist.trackIDs.push(trackID);
    closeTrackContextMenu();
    await persist();
  });
  menu.querySelector("[data-context-new]").onclick = () => {
    closeTrackContextMenu();
    newPlaylist(trackID);
  };
}

async function importAudio() {
  const tracks = await api.importAudio();
  state.tracks.push(...tracks);
  await persist();
  if (!currentID && tracks[0]) currentID = tracks[0].id;
  render(); updateChrome();
}

async function serverAction(mode) {
  const url = $("#serverURL").value.trim();
  const token = $("#serverToken").value;
  serverToken = token;
  const status = $("#serverStatus");
  await saveServerForm();
  status.textContent = mode === "catalog" ? "Loading…" : "Syncing…";
  try {
    let catalog;
    if (mode !== "catalog") {
      const songIDs = mode === "selected" ? [...selectedRemoteIDs] : null;
      if (mode === "selected" && !songIDs.length) throw new Error("Select one or more songs first.");
      const result = await api.syncServer({ baseURL: url, token, existing: state.tracks, songIDs });
      catalog = result.catalog;
      mergeSyncedTracks(state, result);
      status.textContent = `Synced ${result.downloaded.length} new song${result.downloaded.length === 1 ? "" : "s"}`;
      await persist();
    } else {
      catalog = await api.fetchCatalog({ baseURL: url, token });
      status.textContent = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    state.serverURL = url;
    serverCatalog = catalog.songs || [];
    await persist();
    $("#remoteCount").textContent = `${catalog.count} songs`;
    $("#remoteSongs").innerHTML = remoteRows();
    bindRemoteRows();
    renderSidebar();
  } catch (error) {
    status.textContent = error.message || "Connection failed";
  }
}

async function uploadServerSongs() {
  await saveServerForm();
  const status = $("#serverStatus");
  try {
    const result = await api.uploadServer({ baseURL: state.serverURL, adminToken: serverAdminToken });
    status.textContent = `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    await serverAction("catalog");
  } catch (error) { status.textContent = error.message || "Upload failed"; }
}

function play(track) {
  if (!track) return;
  if (currentID && currentID !== track.id) history.push(currentID);
  currentID = track.id;
  state.currentTrackID = currentID;
  audio.src = track.fileUrl;
  audio.volume = Number(state.volume) || 0.78;
  audio.playbackRate = Number($("#speed").value) || 1;
  audio.play().catch((error) => console.error(error));
  persist(); updateChrome(); render();
}

function toggle() {
  const track = currentTrack();
  if (!track) { if (state.tracks[0]) play(state.tracks[0]); return; }
  if (!audio.currentSrc && !audio.src) { play(track); return; }
  audio.paused ? audio.play().catch((error) => console.error(error)) : audio.pause();
  updateChrome();
}

function move(direction) {
  const tracks = playlistTracks();
  const index = nextIndex(tracks, currentID, direction, shuffle);
  if (index >= 0) play(tracks[index]);
}

function toggleFavorite(id) {
  state.favorites = state.favorites.includes(id) ? state.favorites.filter((item) => item !== id) : [...state.favorites, id];
  persist(); render(); updateChrome();
}

function newPlaylist(trackID = null) {
  pendingPlaylistTrackID = typeof trackID === "string" ? trackID : null;
  const dialog = $("#playlistDialog");
  $("#playlistName").value = "";
  dialog.showModal();
  requestAnimationFrame(() => $("#playlistName").focus());
}

function renderSidebar() {
  normalizeState(state);
  $("#sidebarPlaylists").innerHTML = state.playlists.map((playlist) => `<button data-side-playlist="${playlist.id}"><span>${playlist.isSystem ? "♥" : "♪"}</span><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div></button>`).join("");
  document.querySelectorAll("[data-side-playlist]").forEach((button) => button.onclick = () => navigate("library", button.dataset.sidePlaylist));
}

function renderQueue() {
  if (!$("#queue")) return;
  const tracks = playlistTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  const queue = index < 0 ? tracks : [...tracks.slice(index + 1), ...tracks.slice(0, index)];
  $("#queue").innerHTML = queue.slice(0, 12).map((track) => `<button data-queue="${track.id}">${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)}</small></span><time>${formatTime(track.duration)}</time></button>`).join("") || `<div class="empty"><span>Queue is empty</span></div>`;
  document.querySelectorAll("[data-queue]").forEach((button) => button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.queue)));
}

function updateChrome() {
  const track = currentTrack();
  const playing = track && !audio.paused;
  $("#bottomTitle").textContent = track?.title || "Nothing playing";
  $("#bottomMeta").textContent = track ? `${track.artist} / ${playing ? "Now playing" : "Paused"}` : "Local library";
  $(".mini-art").innerHTML = track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪";
  document.querySelectorAll("[data-action=toggle]").forEach((button) => button.textContent = playing ? "Ⅱ" : "▶");
  $("#favoriteCurrent").textContent = track && state.favorites.includes(track.id) ? "♥" : "♡";
  $("#shuffle").classList.toggle("active", shuffle);
  $("#repeat").classList.toggle("active", repeat);
}

function setActiveNav() { document.querySelectorAll(".nav").forEach((button) => button.classList.toggle("active", button.dataset.section === section)); }

function applyNavigation(location) {
  section = location.section;
  selectedPlaylistID = location.playlistID;
  $("#search").value = "";
  setActiveNav(); render();
}

function navigate(nextSection, playlistID = null) {
  const next = { section: nextSection, playlistID };
  const current = navigationHistory[navigationIndex];
  if (current.section === next.section && current.playlistID === next.playlistID) return;
  navigationHistory = navigationHistory.slice(0, navigationIndex + 1);
  navigationHistory.push(next); navigationIndex = navigationHistory.length - 1;
  applyNavigation(next);
}

document.querySelectorAll(".nav").forEach((button) => button.onclick = () => navigate(button.dataset.section));
$("#navBack").onclick = () => { if (navigationIndex > 0) { navigationIndex -= 1; applyNavigation(navigationHistory[navigationIndex]); } };
$("#navForward").onclick = () => { if (navigationIndex + 1 < navigationHistory.length) { navigationIndex += 1; applyNavigation(navigationHistory[navigationIndex]); } };
document.querySelectorAll("[data-action=toggle]").forEach((button) => button.onclick = toggle);
document.querySelectorAll("[data-action=next]").forEach((button) => button.onclick = () => move(1));
document.querySelectorAll("[data-action=previous]").forEach((button) => button.onclick = () => history.length ? play(state.tracks.find((track) => track.id === history.pop())) : move(-1));
$("#newPlaylist").onclick = () => newPlaylist();
$("#cancelPlaylist").onclick = () => { pendingPlaylistTrackID = null; $("#playlistDialog").close(); };
$("#playlistForm").onsubmit = async (event) => {
  event.preventDefault();
  const name = $("#playlistName").value.trim();
  if (!name) return;
  state.playlists.push({ id: crypto.randomUUID(), name, trackIDs: pendingPlaylistTrackID ? [pendingPlaylistTrackID] : [], isSystem: false });
  pendingPlaylistTrackID = null;
  $("#playlistDialog").close();
  await persist();
  render();
};
document.addEventListener("click", (event) => { if (!event.target.closest("#trackContextMenu")) closeTrackContextMenu(); });
document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeTrackContextMenu(); });
window.addEventListener("blur", closeTrackContextMenu);
$("#search").oninput = () => {
  const query = $("#search").value;
  if (section !== "library") {
    navigate("library");
    $("#search").value = query;
  }
  renderLibrary();
};
$("#favoriteCurrent").onclick = () => currentID && toggleFavorite(currentID);
$("#shuffle").onclick = () => { shuffle = !shuffle; state.shuffle = shuffle; persist(); updateChrome(); };
$("#repeat").onclick = () => { repeat = !repeat; state.repeat = repeat; persist(); updateChrome(); };
$("#volume").oninput = async (event) => { audio.volume = Number(event.target.value); state.volume = audio.volume; $("#volumeText").textContent = `${Math.round(audio.volume * 100)}%`; await persist(); };
$("#speed").onchange = (event) => { audio.playbackRate = Number(event.target.value); state.playbackRate = audio.playbackRate; persist(); };
$("#seek").oninput = (event) => { if (audio.duration) audio.currentTime = audio.duration * Number(event.target.value) / 1000; };
audio.ontimeupdate = () => { $("#elapsed").textContent = formatTime(audio.currentTime); $("#duration").textContent = formatTime(audio.duration); $("#seek").value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0"; state.position = audio.currentTime; };
audio.onplay = () => { updateChrome(); renderQueue(); };
audio.onpause = updateChrome;
audio.onended = () => repeat ? play(currentTrack()) : move(1);
audio.onloadedmetadata = async () => { const track = currentTrack(); if (track && audio.duration && track.duration !== audio.duration) { track.duration = audio.duration; await persist(); renderQueue(); } };

state = normalizeState(await api.loadLibrary());
({ clientToken: serverToken = "", adminToken: serverAdminToken = "" } = await api.loadServerCredentials());
shuffle = Boolean(state.shuffle); repeat = Boolean(state.repeat);
$("#volume").value = state.volume;
$("#speed").value = String(state.playbackRate || 1);
$("#volumeText").textContent = `${Math.round(state.volume * 100)}%`;
currentID = state.currentTrackID && state.tracks.some((track) => track.id === state.currentTrackID) ? state.currentTrackID : state.tracks[0]?.id || null;
api.onTransferProgress((value) => {
  const progress = document.querySelector(`#${value.direction}Progress`);
  const detail = document.querySelector(`#${value.direction}Detail`);
  if (progress) progress.value = value.total ? value.completed / value.total : 0;
  if (detail) detail.textContent = `${value.currentFile} • ${value.completed}/${value.total}`;
});
api.onUpdateStatus((value) => {
  const status = $("#updateStatus");
  const install = $("#installUpdate");
  if (!status || !install) return;
  if (value.type === "checking") status.textContent = "Checking GitHub…";
  else if (value.type === "available") status.textContent = `Downloading ${value.version}…`;
  else if (value.type === "downloading") status.textContent = `Downloading… ${value.percent}%`;
  else if (value.type === "ready") { status.textContent = `${value.version} is ready`; install.hidden = false; }
  else if (value.type === "current") status.textContent = "You’re up to date";
  else if (value.type === "error") status.textContent = value.message || "Update check failed";
});
$("#checkForUpdates").onclick = async () => {
  try {
    const result = await api.checkForUpdates();
    if (!result.supported) $("#updateStatus").textContent = "Available in installed builds";
  } catch (error) {
    $("#updateStatus").textContent = error.message || "Update check failed";
  }
};
$("#installUpdate").onclick = () => api.installUpdate();
render(); updateChrome();
