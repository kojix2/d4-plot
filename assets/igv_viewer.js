"use strict";

(async function () {
  const status = document.getElementById("status");
  const desktopButton = document.getElementById("send-desktop");
  const reloadButton = document.getElementById("reload");
  const referenceSelect = document.getElementById("reference");
  const trackPicker = document.getElementById("track-picker");
  const addTrackPicker = document.getElementById("add-track-picker");
  const localSourceButton = document.getElementById("local-source");
  const urlSourceButton = document.getElementById("url-source");
  const trackChoices = document.getElementById("track-choices");
  const loadTracksButton = document.getElementById("load-tracks");
  const localTrackForm = document.getElementById("local-track-form");
  const trackFileInput = document.getElementById("track-file");
  const trackIndexFileInput = document.getElementById("track-index-file");
  const localTrackFormatInput = document.getElementById("local-track-format");
  const localTrackTypeInput = document.getElementById("local-track-type");
  const urlTrackForm = document.getElementById("url-track-form");
  const trackUrlInput = document.getElementById("track-url");
  const trackIndexUrlInput = document.getElementById("track-index-url");
  const urlTrackFormatInput = document.getElementById("url-track-format");
  const urlTrackTypeInput = document.getElementById("url-track-type");
  const root = new URL("./", window.location.href);
  const apiUrl = (path) => new URL(`api/${path}`, root).toString();
  const MAX_DEFAULT_TRACKS = 12;
  const MAX_CONCURRENT_FEATURE_REQUESTS = 2;

  let state;
  let browser;
  let currentLocus;
  let activeFeatureRequests = 0;
  const featureWaiters = [];
  let loadingLocalTrack = false;
  let loadingUrlTrack = false;

  const chooseTrackSource = (source) => {
    const local = source === "local";
    localTrackForm.hidden = !local;
    urlTrackForm.hidden = local;
    localSourceButton.setAttribute("aria-pressed", String(local));
    urlSourceButton.setAttribute("aria-pressed", String(!local));
  };

  const updateTrackButtons = () => {
    localTrackForm.querySelector("button").disabled = !browser || loadingLocalTrack || !trackFileInput.files.length;
    urlTrackForm.querySelector("button").disabled = !browser || loadingUrlTrack || !trackUrlInput.value.trim();
  };

  const addTrack = async (source, index, format, type) => {
    const name = typeof source === "string"
      ? source.split(/[?#]/)[0].split("/").pop() || source
      : source.name;
    const config = {name, url: source};
    if (index) config.indexURL = index;
    if (format) config.format = format.toLowerCase();
    if (type) config.type = type.toLowerCase();
    await browser.loadTrack(config);
    addTrackPicker.open = false;
    show(`Added ${name}.`);
  };

  const show = (message, error = false) => {
    status.textContent = message;
    status.classList.toggle("error", error);
  };

  const requestError = async (response) => {
    let detail = `HTTP ${response.status}`;
    let code = null;
    try {
      const body = await response.json();
      detail = body.message || body.error || detail;
      code = body.error || null;
    } catch (_) {
      // A proxy or browser failure may not have a JSON response.
    }
    const error = new Error(detail);
    error.code = code;
    return error;
  };

  const randomId = () => {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  };

  // IGV may ask several tracks for the same viewport at once. Keep only a
  // small number of network requests in flight so an initial multi-track
  // view does not fill the server's bounded D4 queue before cancellation can
  // become useful. Queued requests remain abortable.
  const acquireFeatureSlot = (signal) => new Promise((resolve, reject) => {
    const abortError = () => new DOMException("D4 request was cancelled", "AbortError");
    const grant = () => {
      activeFeatureRequests += 1;
      resolve(() => {
        activeFeatureRequests -= 1;
        while (featureWaiters.length > 0) {
          const waiter = featureWaiters.shift();
          if (waiter.signal.aborted) {
            waiter.reject(abortError());
            continue;
          }
          waiter.signal.removeEventListener("abort", waiter.onAbort);
          waiter.grant();
          break;
        }
      });
    };
    if (signal.aborted) {
      reject(abortError());
    } else if (activeFeatureRequests < MAX_CONCURRENT_FEATURE_REQUESTS) {
      grant();
    } else {
      const waiter = {signal, grant, reject, onAbort: null};
      waiter.onAbort = () => {
        const index = featureWaiters.indexOf(waiter);
        if (index >= 0) featureWaiters.splice(index, 1);
        reject(abortError());
      };
      signal.addEventListener("abort", waiter.onAbort, {once: true});
      featureWaiters.push(waiter);
    }
  });

  class D4FeatureSource {
    constructor(track) {
      this.track = track;
      this.clientId = `${randomId()}_${track.id}`;
      this.navigation = 0;
      this.controller = null;
      this.approximationShown = false;
    }

    supportsWholeGenome() {
      return false;
    }

    async getFeatures({chr, start, end, bpPerPixel}) {
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return [];
      const navigation = ++this.navigation;
      if (this.controller) this.controller.abort();
      this.controller = new AbortController();
      const controller = this.controller;

      const params = new URLSearchParams({
        track: this.track.id,
        chr: String(chr),
        start: String(start),
        end: String(end),
        bp_per_pixel: String(Number.isFinite(bpPerPixel) && bpPerPixel > 0 ? bpPerPixel : (end - start) / 1000),
        revision: state.revision,
        client: this.clientId,
        navigation: String(navigation),
      });
      try {
        const release = await acquireFeatureSlot(controller.signal);
        try {
          const response = await fetch(`${apiUrl("features")}?${params}`, {
            cache: "no-store",
            signal: controller.signal,
          });
          if (response.status === 409) {
            const error = await requestError(response);
            if (error.code === "QUERY_CANCELLED") return [];
            if (error.code === "SESSION_CHANGED") {
              show("D4 session changed; reloading…");
              window.setTimeout(() => window.location.reload(), 100);
              return [];
            }
            throw error;
          }
          if (!response.ok) throw await requestError(response);
          const payload = await response.json();
          if (payload.revision !== state.revision) {
            show("D4 session changed; reloading…");
            window.setTimeout(() => window.location.reload(), 100);
            return [];
          }
          if (payload.aggregation === "sampled_mean" && !this.approximationShown) {
            this.approximationShown = true;
            show(`${this.track.name}: broad D4 ranges without a usable sum index use sampled bin means; zoom in for exact values.`);
          }
          return payload.features.map((feature) => ({
            chr: payload.chr,
            start: feature.start,
            end: feature.end,
            value: feature.value,
          }));
        } finally {
          release();
        }
      } catch (error) {
        if (error && error.name === "AbortError") return [];
        show(error.message || String(error), true);
        throw error;
      }
    }
  }

  const setReferenceChoices = () => {
    referenceSelect.replaceChildren();
    for (const choice of state.referenceChoices) {
      const option = document.createElement("option");
      option.value = choice.id;
      option.selected = choice.selected;
      option.textContent = choice.label || choice.id;
      referenceSelect.append(option);
    }
    referenceSelect.disabled = false;
  };

  const selectedTrackIds = () => {
    const defaults = new Set(state.tracks.slice(0, MAX_DEFAULT_TRACKS).map((track) => track.id));
    const value = new URL(window.location.href).searchParams.get("tracks");
    if (value === null) return defaults;
    if (value === "") return new Set();
    const requested = new Set(value.split(",").filter((id) => state.tracks.some((track) => track.id === id)));
    // A server revision can retire a source. Do not strand a user on an empty
    // viewer because a bookmarked/old opaque id no longer exists.
    return requested.size > 0 ? requested : defaults;
  };

  const setTrackChoices = (selected) => {
    trackPicker.hidden = state.tracks.length === 0;
    trackChoices.replaceChildren();
    for (const track of state.tracks) {
      const label = document.createElement("label");
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.value = track.id;
      checkbox.checked = selected.has(track.id);
      label.append(checkbox, document.createTextNode(` ${track.name} (${track.compatibility})`));
      trackChoices.append(label);
    }
  };

  const selectedTrackChoiceIds = () => Array.from(trackChoices.querySelectorAll("input[type=checkbox]:checked"), (checkbox) => checkbox.value);

  const lociFromEvent = (payload) => {
    const frames = Array.isArray(payload) ? payload : (Array.isArray(payload && payload.referenceFrameList) ? payload.referenceFrameList : [payload]);
    return frames
      .filter((frame) => frame && typeof frame.getLocusString === "function")
      .map((frame) => frame.getLocusString())
      .filter((locus) => typeof locus === "string" && locus.length > 0);
  };

  const setDesktopLocus = (payload) => {
    const loci = lociFromEvent(payload);
    if (loci.length === 1 && loci[0].toLowerCase() !== "all") {
      currentLocus = loci[0];
      desktopButton.disabled = !state.desktopGotoAvailable;
      return;
    }
    // Do not silently send the first pane of an IGV multi-locus view to the
    // Desktop application. The user must return to one locus before sending.
    currentLocus = null;
    desktopButton.disabled = true;
    show("Show a single locus before sending it to IGV Desktop.");
  };

  try {
    if (!window.igv) throw new Error("IGV.js could not load. Verify the bundled IGV.js asset.");
    const response = await fetch(apiUrl("state"), {cache: "no-store"});
    if (!response.ok) throw await requestError(response);
    state = await response.json();
    // The server validates a requested `?locus=` against the current
    // immutable reference.  Use its normalized fallback rather than sending
    // an invalid raw query string directly to IGV.js.
    currentLocus = state.locus;
    setReferenceChoices();
    const selectedIds = selectedTrackIds();
    setTrackChoices(selectedIds);
    const selectedTracks = state.tracks.filter((track) => selectedIds.has(track.id));
    const d4Sources = selectedTracks.map((track) => new D4FeatureSource(track));
    const tracks = selectedTracks.map((track, index) => ({
      name: track.name,
      type: "wig",
      featureSource: d4Sources[index],
      // The service already returns resolution-aware means.  Letting WigTrack
      // summarize those means again changes their numerical meaning.
      summarize: false,
      windowFunction: "none",
      supportsWholeGenome: false,
      searchable: false,
      color: "#23549a",
      altColor: "#a13030",
      autoscale: true,
      height: 110,
    }));

    const config = {
      ...state.igvReference,
      locus: currentLocus,
      tracks,
      showNavigation: true,
      showRuler: true,
    };
    browser = await window.igv.createBrowser(document.getElementById("igv"), config);
    browser.on("locuschange", setDesktopLocus);
    updateTrackButtons();

    desktopButton.disabled = !state.desktopGotoAvailable;
    desktopButton.title = state.desktopGotoAvailable
      ? "Send this locus to a running IGV Desktop"
      : "A reference with a verified contig dictionary is required";
    const omitted = state.tracks.length - tracks.length;
    const sampledNote = d4Sources.some((source) => source.approximationShown)
      ? " · Wide D4 view uses sampled depth" : "";
    const trackMessage = tracks.length === 0 ? "Genome browser ready" :
      `${tracks.length} D4 track${tracks.length === 1 ? "" : "s"} loaded${omitted > 0 ? ` (${omitted} not selected)` : ""}`;
    show(`${trackMessage}${sampledNote}`);
  } catch (error) {
    show(error.message || String(error), true);
  }

  reloadButton.addEventListener("click", () => window.location.reload());
  localSourceButton.addEventListener("click", () => chooseTrackSource("local"));
  urlSourceButton.addEventListener("click", () => chooseTrackSource("url"));
  for (const menu of [trackPicker, addTrackPicker]) {
    menu.addEventListener("toggle", () => {
      if (menu.open) {
        for (const other of [trackPicker, addTrackPicker]) {
          if (other !== menu) other.open = false;
        }
      }
    });
  }
  document.addEventListener("pointerdown", (event) => {
    for (const menu of [trackPicker, addTrackPicker]) {
      if (menu.open && !menu.contains(event.target)) menu.open = false;
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    for (const menu of [trackPicker, addTrackPicker]) {
      if (menu.open) {
        menu.open = false;
        menu.querySelector("summary").focus();
      }
    }
  });
  trackFileInput.addEventListener("change", updateTrackButtons);
  trackUrlInput.addEventListener("input", updateTrackButtons);
  localTrackForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!browser || !trackFileInput.files.length) return;
    loadingLocalTrack = true;
    updateTrackButtons();
    try {
      await addTrack(trackFileInput.files[0], trackIndexFileInput.files[0],
        localTrackFormatInput.value.trim(), localTrackTypeInput.value.trim());
      localTrackForm.reset();
    } catch (error) {
      show(`Could not add track: ${error.message || String(error)}`, true);
    } finally {
      loadingLocalTrack = false;
      updateTrackButtons();
    }
  });
  urlTrackForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!browser || !trackUrlInput.value.trim()) return;
    loadingUrlTrack = true;
    updateTrackButtons();
    try {
      await addTrack(trackUrlInput.value.trim(), trackIndexUrlInput.value.trim(),
        urlTrackFormatInput.value.trim(), urlTrackTypeInput.value.trim());
      urlTrackForm.reset();
    } catch (error) {
      show(`Could not add track: ${error.message || String(error)}`, true);
    } finally {
      loadingUrlTrack = false;
      updateTrackButtons();
    }
  });
  loadTracksButton.addEventListener("click", () => {
    const ids = selectedTrackChoiceIds();
    const next = new URL(window.location.href);
    next.searchParams.set("tracks", ids.join(","));
    window.location.assign(next);
  });
  referenceSelect.addEventListener("change", async () => {
    referenceSelect.disabled = true;
    try {
      const response = await fetch(apiUrl("reference"), {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({id: referenceSelect.value}),
      });
      if (!response.ok) throw await requestError(response);
      window.location.reload();
    } catch (error) {
      show(error.message || String(error), true);
      referenceSelect.disabled = false;
    }
  });
  desktopButton.addEventListener("click", async () => {
    if (!state.desktopGotoAvailable || !currentLocus) return;
    desktopButton.disabled = true;
    try {
      const response = await fetch(apiUrl("desktop-goto"), {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({locus: currentLocus}),
      });
      if (!response.ok) throw await requestError(response);
      show(`Sent ${currentLocus} to IGV Desktop`);
    } catch (error) {
      show(error.message || String(error), true);
    } finally {
      desktopButton.disabled = !state.desktopGotoAvailable || !currentLocus;
    }
  });
})();
