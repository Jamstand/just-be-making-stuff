// Claude Assistant for After Effects — ExtendScript host side.
// RULES OF THIS FILE (the engine is ECMA-262 3rd edition, doc-verified):
// var only, no JSON object, no arrow functions, no const/let, no template
// strings. The panel calls CA_invoke(name, argsJsonString) and gets a JSON
// string back — always, even for errors (never a bare throw: evalScript
// collapses every host error into the useless "EvalScript error.").

// --- minimal JSON out (ES3). Input parsing uses eval — acceptable because
// the only caller is our own panel, which builds the string with real JSON.
function CA_str(v) {
  var i, out, k;
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return isFinite(v) ? String(v) : "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "string") {
    return '"' + v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
                  .replace(/\n/g, "\\n").replace(/\r/g, "\\r")
                  .replace(/\t/g, "\\t") + '"';
  }
  if (Object.prototype.toString.call(v) === "[object Array]") {
    out = [];
    for (i = 0; i < v.length; i++) out.push(CA_str(v[i]));
    return "[" + out.join(",") + "]";
  }
  out = [];
  for (k in v) if (v.hasOwnProperty(k)) out.push(CA_str(k) + ":" + CA_str(v[k]));
  return "{" + out.join(",") + "}";
}

function CA_err(msg) { throw new Error(msg); }

function CA_comp(name) {
  var i, it;
  if (name) {
    for (i = 1; i <= app.project.numItems; i++) {
      it = app.project.item(i);
      if (it instanceof CompItem && it.name === name) return it;
    }
    CA_err("No comp named '" + name + "'.");
  }
  it = app.project.activeItem;
  if (it && it instanceof CompItem) return it;
  CA_err("No active comp — open one or pass comp by name.");
}

function CA_layer(comp, index) {
  var n = parseInt(index, 10);
  if (!n || n < 1 || n > comp.numLayers)
    CA_err("Comp '" + comp.name + "' has " + comp.numLayers +
           " layers; layer must be 1.." + comp.numLayers + ".");
  return comp.layer(n);
}

function CA_item(name) {
  var i, it;
  for (i = 1; i <= app.project.numItems; i++) {
    it = app.project.item(i);
    if (it.name === name) return it;
  }
  CA_err("No project item named '" + name + "'.");
}

var CA_TOOLS = {};

CA_TOOLS.get_project_overview = function (a) {
  var out = { project: app.project.file ? app.project.file.name : "(unsaved)",
              items: [], comps: [] };
  var i, it;
  for (i = 1; i <= app.project.numItems; i++) {
    it = app.project.item(i);
    if (it instanceof CompItem)
      out.comps.push({ name: it.name, width: it.width, height: it.height,
                       fps: it.frameRate, duration_s: it.duration,
                       layers: it.numLayers,
                       active: app.project.activeItem === it });
    else
      out.items.push({ name: it.name,
                       type: it instanceof FootageItem ? "footage" : "folder",
                       duration_s: it.duration || 0 });
  }
  out.scripting_write_enabled = app.preferences.getPrefAsLong(
    "Main Pref Section", "Pref_SCRIPTING_FILE_NETWORK_SECURITY") === 1;
  return out;
};

CA_TOOLS.import_media = function (a) {
  var out = [], i, f, io, item;
  for (i = 0; i < a.paths.length; i++) {
    f = new File(a.paths[i]);
    if (!f.exists) { out.push({ path: a.paths[i], error: "not found" });
                     continue; }
    io = new ImportOptions(f);
    item = app.project.importFile(io);
    out.push({ path: a.paths[i], name: item.name,
               duration_s: item.duration || 0 });
  }
  return { imported: out };
};

CA_TOOLS.create_comp = function (a) {
  var c = app.project.items.addComp(
    a.name || "Claude Comp",
    parseInt(a.width, 10) || 1080, parseInt(a.height, 10) || 1920,
    1.0, Number(a.duration_s) || 30, Number(a.fps) || 59.94);
  c.openInViewer();
  return { comp: c.name, width: c.width, height: c.height,
           fps: c.frameRate, duration_s: c.duration };
};

CA_TOOLS.add_clip = function (a) {
  var comp = CA_comp(a.comp);
  var item = CA_item(a.item_name);
  var layer = comp.layers.add(item);
  // AE semantics (doc-verified): inPoint/outPoint/startTime are all COMP
  // time. To show SOURCE [in_s, out_s] starting at comp start_s: shift the
  // layer so source in_s lands on start_s, then trim in comp time.
  var srcIn = Number(a.in_s) || 0;
  var srcOut = a.out_s !== undefined ? Number(a.out_s)
                                     : srcIn + (item.duration || 0);
  var start = a.start_s !== undefined ? Number(a.start_s) : 0;
  layer.startTime = start - srcIn;
  layer.inPoint = start;
  layer.outPoint = start + (srcOut - srcIn);
  layer.moveToEnd();       // append order: new clips go under existing ones
  return { layer: comp.numLayers, name: layer.name,
           source_in_s: srcIn, source_out_s: srcOut,
           comp_start_s: layer.inPoint, comp_end_s: layer.outPoint };
};

CA_TOOLS.speed_ramp = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  if (!layer.canSetTimeRemapEnabled)
    CA_err("This layer type cannot be time-remapped.");
  layer.timeRemapEnabled = true;
  var tr = layer.property("ADBE Time Remapping");
  var i, k, key;
  // wipe default keys, then lay ours
  while (tr.numKeys > 0) tr.removeKey(1);
  for (i = 0; i < a.keys.length; i++) {
    k = a.keys[i];
    tr.setValueAtTime(Number(k.at_s), Number(k.source_s));
  }
  for (i = 0; i < a.keys.length; i++) {
    k = a.keys[i];
    if (k.ease_influence !== undefined || k.ease_speed !== undefined) {
      var ease = new KeyframeEase(Number(k.ease_speed) || 0,
        Math.max(0.1, Math.min(100, Number(k.ease_influence) || 33)));
      tr.setTemporalEaseAtKey(i + 1, [ease], [ease]);
    }
  }
  // extend the layer to cover remapped time
  layer.outPoint = Number(a.keys[a.keys.length - 1].at_s);
  return { layer: layer.name, keys: tr.numKeys,
           out_s: layer.outPoint };
};

CA_TOOLS.set_keyframes = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var prop = layer, i;
  for (i = 0; i < a.path.length; i++) {
    prop = prop.property(a.path[i]);
    if (!prop) CA_err("No property '" + a.path[i] + "' at depth " + i + ".");
  }
  if (a.keys.length === 1 && a.keys[0].at_s === undefined) {
    prop.setValue(a.keys[0].value);
    return { property: prop.name, set: "static", value_set: true };
  }
  for (i = 0; i < a.keys.length; i++)
    prop.setValueAtTime(Number(a.keys[i].at_s), a.keys[i].value);
  if (a.hold)
    for (i = 1; i <= prop.numKeys; i++)
      prop.setInterpolationTypeAtKey(i, KeyframeInterpolationType.HOLD);
  return { property: prop.name, keys: prop.numKeys };
};

CA_TOOLS.apply_effect = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var fx = layer.property("ADBE Effect Parade").addProperty(a.effect);
  var set = [], k, p;
  for (k in (a.settings || {})) {
    if (!a.settings.hasOwnProperty(k)) continue;
    p = fx.property(k);
    if (p) { p.setValue(a.settings[k]); set.push(k); }
    else set.push(k + " (NOT FOUND)");
  }
  // report the effect's real property names so the model can iterate
  var props = [], i;
  for (i = 1; i <= fx.numProperties; i++)
    props.push(fx.property(i).matchName + " | " + fx.property(i).name);
  return { effect: fx.name, applied_to: layer.name, set: set,
           properties: props };
};

CA_TOOLS.add_text = function (a) {
  var comp = CA_comp(a.comp);
  var layer = comp.layers.addText(a.text || "TEXT");
  var doc = layer.property("ADBE Text Properties")
                 .property("ADBE Text Document");
  var td = doc.value;
  if (a.font) td.font = a.font;
  if (a.size) td.fontSize = Number(a.size);
  if (a.color) td.fillColor = a.color;
  if (a.tracking !== undefined) td.tracking = Number(a.tracking);
  doc.setValue(td);
  if (a.position) layer.property("ADBE Transform Group")
    .property("ADBE Position").setValue(a.position);
  if (a.start_s !== undefined) layer.startTime = Number(a.start_s);
  if (a.duration_s !== undefined)
    layer.outPoint = layer.startTime + Number(a.duration_s);
  return { layer: comp.numLayers, text: a.text,
           start_s: layer.startTime, out_s: layer.outPoint };
};

CA_TOOLS.add_mask = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var mask = layer.property("ADBE Mask Parade").addProperty("ADBE Mask Atom");
  var shape = new Shape();
  shape.vertices = a.vertices;
  shape.closed = a.closed === undefined ? true : !!a.closed;
  mask.property("ADBE Mask Shape").setValue(shape);
  if (a.inverted) mask.inverted = true;
  if (a.feather !== undefined)
    mask.property("ADBE Mask Feather")
        .setValue([Number(a.feather), Number(a.feather)]);
  if (a.mode === "subtract") mask.maskMode = MaskMode.SUBTRACT;
  return { layer: layer.name, masks: layer.property("ADBE Mask Parade").numProperties };
};

// saveFrameToPng (undocumented, asynchronous since CC2015) creates the
// file first and finishes it on AE's main thread. Never wait for it HERE:
// a $.sleep loop inside ExtendScript blocks that same thread, the PNG
// stalls half-written, and every later evalScript queues behind the loop
// (live: "every script call times out"). The panel waits on the file.
function CA_grabDir() {
  var dir = new Folder(Folder.userData.fsName + "/ClaudeAssistantAE");
  if (!dir.exists) dir.create();
  return dir;
}

CA_TOOLS.grab_frame = function (a) {
  var comp = CA_comp(a.comp);
  var t = a.time_s !== undefined ? Number(a.time_s) : comp.time;
  var f = new File(CA_grabDir().fsName + "/frame_" + new Date().getTime() + ".png");
  if (typeof comp.saveFrameToPng !== "function")
    CA_err("saveFrameToPng is missing in this AE version — frame export "
           + "needs the render-queue fallback (not yet built).");
  comp.saveFrameToPng(t, f);
  return { file: f.fsName, time_s: t, comp: comp.name };
};

// A layer's SOURCE, rendered alone in a throwaway comp: the frame the
// tracking tools need, in source pixels, without the rest of the stack.
// The panel removes the temp comp (remove_temp_comp) once the PNG is done.
CA_TOOLS.grab_source_frame = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var src = layer.source;
  if (!src) CA_err("Layer '" + layer.name + "' has no source to render.");
  var t = a.source_time_s !== undefined ? Number(a.source_time_s) : 0;
  var fps = src.frameRate || comp.frameRate;
  var dur = Math.max(src.duration || 0, 1 / fps);
  var name = "__ClaudeGrab__" + new Date().getTime();
  var tmp = app.project.items.addComp(name, src.width, src.height,
                                      src.pixelAspect || 1, dur, fps);
  var f = new File(CA_grabDir().fsName + "/source_" + new Date().getTime() + ".png");
  try {
    tmp.layers.add(src);
    if (typeof tmp.saveFrameToPng !== "function")
      CA_err("saveFrameToPng is missing in this AE version.");
    tmp.saveFrameToPng(Math.max(0, Math.min(t, dur - 1 / fps)), f);
  } catch (e) {
    try { tmp.remove(); } catch (e2) {}      // never leave a grab comp behind
    throw e;
  }
  return { file: f.fsName, source_time_s: t, source: src.name,
           width: src.width, height: src.height, temp_comp: name };
};

CA_TOOLS.remove_temp_comp = function (a) {
  var removed = 0, i, item;
  for (i = app.project.numItems; i >= 1; i--) {
    item = app.project.item(i);
    if (item instanceof CompItem && item.name.indexOf("__ClaudeGrab__") === 0
        && (!a.name || item.name === a.name)) { item.remove(); removed += 1; }
  }
  return { removed: removed };
};

// --------------------------------------------------- style study frames
// Sampling a finished edit for the style study WITHOUT ffmpeg: After
// Effects decodes the video itself. The file is imported into a folder
// named __ClaudeStudy__ and a tiny comp (the sample size, with the source
// squashed to fill it exactly as ffmpeg's scale filter would) is rendered
// with saveFrameToPng at each requested time. Only what is inside that
// folder is ever removed, so footage the user already had is never touched.
var CA_STUDY_FOLDER = "__ClaudeStudy__";
var CA_STUDY_COMP = "__ClaudeStudyFrame__";

function CA_studyFolder(make) {
  var i, it;
  for (i = 1; i <= app.project.numItems; i++) {
    it = app.project.item(i);
    if (it instanceof FolderItem && it.name === CA_STUDY_FOLDER) return it;
  }
  return make ? app.project.items.addFolder(CA_STUDY_FOLDER) : null;
}

function CA_studyComp() {
  var i, it;
  for (i = 1; i <= app.project.numItems; i++) {
    it = app.project.item(i);
    if (it instanceof CompItem && it.name === CA_STUDY_COMP) return it;
  }
  return null;
}

function CA_studyFrameDir() {
  var dir = new Folder(CA_grabDir().fsName + "/study-frames");
  if (!dir.exists) dir.create();
  return dir;
}

CA_TOOLS.study_open = function (a) {
  var f = new File(String(a.file)), item = null, comp, l, w, h, fps, io;
  var longEdge, k, sc, bpc = null, space = null;
  if (!f.exists) CA_err("No such file: " + a.file);
  if (app.preferences.getPrefAsLong("Main Pref Section",
      "Pref_SCRIPTING_FILE_NETWORK_SECURITY") !== 1)
    CA_err("After Effects will not let scripts write files, so frames cannot "
           + "be saved. Turn on Preferences > Scripting & Expressions > Allow "
           + "Scripts to Write Files and Access Network, then try again.");
  CA_TOOLS.study_close({});                  // never two studies at once
  var folder = CA_studyFolder(true);
  io = new ImportOptions(f);
  try { if (typeof io.canImportAs === "function" && typeof ImportAsType !== "undefined"
            && !io.canImportAs(ImportAsType.FOOTAGE))
          CA_err("After Effects cannot import " + f.name + " as footage — an "
                 + "unsupported codec (VP9/AV1/WebM are not read natively)."); }
  catch (e0) { if (e0 && /cannot import/.test(String(e0.message || e0))) { CA_TOOLS.study_close({}); throw e0; } }
  try { item = app.project.importFile(io); }
  catch (e) {
    CA_TOOLS.study_close({});
    CA_err("After Effects could not import " + f.name + " (" + (e.message || e)
           + ") — a codec it does not read (VP9/AV1/WebM are not native)?");
  }
  item.parentFolder = folder;
  if (item.footageMissing) {
    CA_TOOLS.study_close({});
    CA_err(f.name + " imported but After Effects reports the footage as missing.");
  }
  if (!(item.duration > 0)) {
    CA_TOOLS.study_close({});
    CA_err(f.name + " imported with no duration — a still image rather than a video?");
  }
  // The temp comp keeps the source's SHAPE, shrunk by a whole-ish factor:
  // After Effects does a clean uniform downscale and the panel does the rest
  // in integer arithmetic, so both routes end up measuring the same picture.
  fps = item.frameRate > 0 ? item.frameRate : 30;
  longEdge = parseInt(a.long_edge, 10) || 240;
  k = Math.max(1, Math.round(Math.max(item.width, item.height) / longEdge));
  w = Math.max(4, Math.round(item.width / k));
  h = Math.max(4, Math.round(item.height / k));
  comp = app.project.items.addComp(CA_STUDY_COMP, w, h, 1, item.duration, fps);
  if (typeof comp.saveFrameToPng !== "function") {
    CA_TOOLS.study_close({});
    CA_err("saveFrameToPng is missing in this After Effects version, so the "
           + "panel cannot read frames without ffmpeg.");
  }
  comp.parentFolder = folder;
  try { comp.resolutionFactor = [1, 1]; } catch (e2) {}
  l = comp.layers.add(item);
  try { l.quality = LayerQuality.BEST; } catch (e3) {}
  // uniform, and rounded UP so rounding never leaves a transparent edge
  sc = 100 * Math.max(w / item.width, h / item.height);
  l.property("ADBE Transform Group").property("ADBE Scale").setValue([sc, sc]);
  try { bpc = app.project.bitsPerChannel; } catch (e4) {}
  try { space = app.project.workingSpace; } catch (e5) {}
  return { item: item.name, comp: comp.name, duration_s: item.duration,
           fps: fps, width: item.width, height: item.height,
           sample_width: w, sample_height: h, scale_pct: sc,
           project_bpc: bpc, working_space: space,
           frame_dir: CA_studyFrameDir().fsName };
};

// One batch of frames: stops early when budget_ms is spent so a long edit
// never blocks After Effects in a single call.
CA_TOOLS.study_sample = function (a) {
  var comp = CA_studyComp(), i, t, f, files = [], t0 = new Date().getTime();
  if (!comp) CA_err("No study comp is open — call study_open first.");
  var dir = CA_studyFrameDir();
  var times = a.times || [];
  // an explicit 0 means "one frame per call", so it must not fall through
  // to the default the way `Number(0) || 8000` would
  var budget = (a.budget_ms === undefined || a.budget_ms === null) ? 8000 : Number(a.budget_ms);
  if (!(budget >= 0)) budget = 8000;
  var base = parseInt(a.index, 10) || 0;
  var last = Math.max(0, comp.duration - 1 / comp.frameRate);
  for (i = 0; i < times.length; i++) {
    if (i > 0 && new Date().getTime() - t0 >= budget) break;
    t = Number(times[i]);
    if (!(t >= 0)) t = 0;
    if (t > last) t = last;
    f = new File(dir.fsName + "/s" + (base + i) + ".png");
    // saveFrameToPng hands back a file-like object that carries its own
    // exception when the render failed — the only error surface it has.
    var res = comp.saveFrameToPng(t, f);
    if (res && res._hasException)
      CA_err("After Effects could not render the frame at " + t + "s: "
             + (res.exception || "no detail"));
    files.push({ t: t, file: f.fsName });
  }
  return { files: files, wrote: files.length, next_index: base + files.length,
           elapsed_ms: new Date().getTime() - t0 };
};

CA_TOOLS.study_close = function (a) {
  var folder = CA_studyFolder(false), removed = 0, i, it;
  if (!folder) return { removed: 0 };
  // comps first: dropping footage a comp still uses would empty it noisily
  for (i = folder.numItems; i >= 1; i--) {
    it = folder.item(i);
    if (it instanceof CompItem) { it.remove(); removed += 1; }
  }
  for (i = folder.numItems; i >= 1; i--) { folder.item(i).remove(); removed += 1; }
  folder.remove();
  return { removed: removed };
};

CA_TOOLS.render = function (a) {
  var comp = CA_comp(a.comp);
  var rqi = app.project.renderQueue.items.add(comp);
  var om = rqi.outputModule(1);
  if (a.om_template) om.applyTemplate(a.om_template);
  if (a.rs_template) rqi.applyTemplate(a.rs_template);
  om.file = new File(a.output);
  if (a.use_ame) {
    app.project.renderQueue.queueInAME(true);
    return { queued_in_ame: true, output: a.output };
  }
  app.project.renderQueue.render();     // blocks until done
  return { status: String(rqi.status), output: a.output,
           done: rqi.status === RQItemStatus.DONE };
};

CA_TOOLS.list_render_templates = function (a) {
  var comp = CA_comp(a.comp);
  var rqi = app.project.renderQueue.items.add(comp);
  var out = { output_modules: rqi.outputModule(1).templates,
              render_settings: rqi.templates };
  rqi.remove();
  return out;
};

CA_TOOLS.run_extendscript = function (a) {
  var result = eval(a.code);
  return { result: result === undefined ? null : result };
};

// ------------------------------------------------- tracking bridge (host)
// AE's own analysis stays unscriptable; these are the data-side halves the
// panel pairs with Mocha Pro's Python and fal.ai SAM 3.

CA_TOOLS.layer_info = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var stretch = (layer.stretch !== undefined && layer.stretch)
                ? Number(layer.stretch) : 100;
  var out = { comp: comp.name, comp_width: comp.width, comp_height: comp.height,
              comp_fps: comp.frameRate, layer: layer.name, index: layer.index,
              start_s: layer.startTime, in_s: layer.inPoint,
              out_s: layer.outPoint, stretch: stretch,
              time_remap: !!layer.timeRemapEnabled, has_video: !!layer.hasVideo,
              source: null };
  var src = null;
  try { src = layer.source; } catch (e) { src = null; }
  if (src) {
    var ms = null, file = null, still = false;
    try { ms = src.mainSource; } catch (e2) { ms = null; }
    if (ms) {
      try { if (ms.file) file = ms.file.fsName; } catch (e3) {}
      try { still = !!ms.isStill; } catch (e4) {}
    }
    out.source = { name: src.name, width: src.width, height: src.height,
                   fps: src.frameRate, duration_s: src.duration, file: file,
                   is_still: still, is_comp: (src instanceof CompItem) };
    // comp time -> source time: (t - start) * 100 / stretch
    out.source_in_s = (layer.inPoint - layer.startTime) * 100 / stretch;
    out.source_out_s = (layer.outPoint - layer.startTime) * 100 / stretch;
  }
  try {
    var tr = layer.property("ADBE Transform Group");
    out.position = tr.property("ADBE Position").value;
    out.scale = tr.property("ADBE Scale").value;
    out.anchor = tr.property("ADBE Anchor Point").value;
  } catch (e5) {}
  return out;
};

// Blocks parsed from "Adobe After Effects 8.0 Keyframe Data" text (what
// Mocha's Corner Pin / Power Pin / Transform exporters write). Frame f of
// the SOURCE lands at comp time offset + f/fps * stretch.
CA_TOOLS.apply_keyframe_data = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var fps = Number(a.fps) || comp.frameRate;
  var offset = Number(a.time_offset_s) || 0;
  var stretch = (Number(a.stretch) || 100) / 100;
  var known = { "Corner Pin": "ADBE Corner Pin", "CC Power Pin": "CC Power Pin" };
  var applied = [], i, j, b, base, pname, fx, target, val, dims, group, label;
  if (!a.blocks || !a.blocks.length) CA_err("No keyframe blocks to apply.");
  for (i = 0; i < a.blocks.length; i++) {
    b = a.blocks[i]; fx = null;
    base = String(b.name || "").replace(/\s*#\d+\s*$/, "");
    pname = String(b.prop || "").replace(/\s*#\d+\s*$/, "");
    if (b.group === "Effects") {
      group = layer.property("ADBE Effect Parade");
      // A labelled run owns only the effect carrying its own label; the
      // first Corner Pin on the layer may be another chat's work.
      if (a.effect_name) fx = group.property(String(a.effect_name));
      else fx = group.property(base) || (known[base] ? group.property(known[base]) : null);
      if (!fx) {
        fx = group.addProperty(known[base] || base);
        if (a.effect_name) { try { fx.name = String(a.effect_name); } catch (e) {} }
      }
      target = pname ? fx.property(pname) : null;
      if (!target) CA_err("Effect '" + fx.name + "' has no property '" + pname + "'.");
      label = fx.name + " > " + target.name;
    } else if (b.group === "Transform") {
      group = layer.property("ADBE Transform Group");
      target = group.property(base);
      if (!target && base === "Rotation") target = group.property("ADBE Rotate Z");
      if (!target) CA_err("No transform property '" + base + "'.");
      label = "Transform > " + target.name;
    } else {
      CA_err("Unsupported keyframe group '" + b.group + "' (Effects and Transform only).");
    }
    if (a.replace !== false) while (target.numKeys > 0) target.removeKey(1);
    val = target.value;
    dims = (val !== null && typeof val === "object" && val.length !== undefined)
           ? val.length : 1;
    for (j = 0; j < b.keys.length; j++) {
      val = b.keys[j].values;
      if (dims === 1) val = Number(val[0]);
      else { val = val.slice(0, dims); while (val.length < dims) val.push(0); }
      target.setValueAtTime(offset + (Number(b.keys[j].frame) / fps) * stretch, val);
    }
    applied.push({ target: label, keys: target.numKeys });
  }
  return { layer: layer.name, fps: fps, offset_s: offset, applied: applied };
};

// Native mask keyframes from per-frame vertex lists (Mocha's shape export,
// parsed panel-side). Straight tangents; RotoBezier lets AE smooth them.
// Called in chunks: append=true adds keys to the mask of the same name.
CA_TOOLS.apply_mask_keyframes = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var masks = layer.property("ADBE Mask Parade");
  var fps = Number(a.fps) || comp.frameRate;
  var offset = Number(a.time_offset_s) || 0;
  var stretch = (Number(a.stretch) || 100) / 100;
  var name = a.name || "Mocha Mask";
  var mask = null, i, j, f, shape, mp, zeros;
  if (!a.frames || !a.frames.length) CA_err("No mask frames to apply.");
  for (i = 1; i <= masks.numProperties; i++)
    if (masks.property(i).name === name) { mask = masks.property(i); break; }
  if (mask && !a.append && a.replace !== false) { mask.remove(); mask = null; }
  if (!mask) { mask = masks.addProperty("ADBE Mask Atom"); mask.name = name; }
  mp = mask.property("ADBE Mask Shape");
  for (i = 0; i < a.frames.length; i++) {
    f = a.frames[i];
    if (!f.points || f.points.length < 3) continue;
    shape = new Shape();
    shape.vertices = f.points;
    zeros = [];
    for (j = 0; j < f.points.length; j++) zeros.push([0, 0]);
    shape.inTangents = zeros;
    shape.outTangents = zeros;
    shape.closed = true;
    mp.setValueAtTime(offset + (Number(f.frame) / fps) * stretch, shape);
  }
  if (!a.append) {
    if (a.mode === "subtract") mask.maskMode = MaskMode.SUBTRACT;
    else if (a.mode === "none") mask.maskMode = MaskMode.NONE;
    if (a.feather !== undefined)
      mask.property("ADBE Mask Feather")
          .setValue([Number(a.feather), Number(a.feather)]);
    if (a.inverted) mask.inverted = true;
    if (a.roto_bezier !== false) { try { mask.rotoBezier = true; } catch (e) {} }
  }
  var verts = 0;
  for (i = 0; i < a.frames.length && !verts; i++)
    if (a.frames[i].points && a.frames[i].points.length >= 3) verts = a.frames[i].points.length;
  return { layer: layer.name, mask: mask.name, keys: mp.numKeys,
           first_key_s: mp.numKeys ? mp.keyTime(1) : null,
           last_key_s: mp.numKeys ? mp.keyTime(mp.numKeys) : null,
           vertices: verts };
};

// Mocha's "After Effects Mask Data" only enters AE through the clipboard:
// Edit > Paste Mocha mask (the panel puts the text there first). The menu
// id is looked up by name (locale-dependent) with the AE 2025 id as a
// fallback.
CA_TOOLS.paste_mocha_mask = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var masks = layer.property("ADBE Mask Parade");
  var before = masks.numProperties, i, id = 0, m, mp, added = [];
  var names = ["Paste Mocha mask", "Paste mocha mask", "Paste Mocha Mask"];
  for (i = 1; i <= comp.numLayers; i++) comp.layer(i).selected = false;
  layer.selected = true;
  if (a.time_s !== undefined) comp.time = Number(a.time_s);
  for (i = 0; i < names.length && !id; i++) {
    try { id = app.findMenuCommandId(names[i]) || 0; } catch (e) { id = 0; }
  }
  if (!id) id = 5007;
  comp.openInViewer();                       // menu commands act on the active comp
  app.executeCommand(id);
  var after = masks.numProperties;
  for (i = before + 1; i <= after; i++) {
    m = masks.property(i);
    mp = m.property("ADBE Mask Shape");
    added.push({ mask: m.name, keys: mp.numKeys,
                 first_key_s: mp.numKeys ? mp.keyTime(1) : null,
                 last_key_s: mp.numKeys ? mp.keyTime(mp.numKeys) : null });
  }
  if (after === before)
    CA_err("'Paste Mocha mask' (menu id " + id + ") added no mask. Is the "
           + "clipboard holding After Effects Mask Data, and is the Mocha "
           + "plug-in installed in this AE?");
  return { layer: layer.name, menu_id: id, masks_added: added };
};

// Import a rendered matte (e.g. fal's segmented video) above a layer and
// make it that layer's track matte (AE 23+ per-layer matte API).
CA_TOOLS.import_and_matte = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var f = new File(a.file);
  if (!f.exists) CA_err("File not found: " + a.file);
  var item = app.project.importFile(new ImportOptions(f));
  var matte = comp.layers.add(item);
  matte.moveBefore(layer);
  matte.startTime = layer.startTime;
  matte.inPoint = layer.inPoint;
  if (matte.outPoint > layer.outPoint) matte.outPoint = layer.outPoint;
  var kind = a.matte || "luma", type = null;
  if (kind !== "none") {
    if (typeof layer.setTrackMatte !== "function")
      CA_err("setTrackMatte needs After Effects 23 or newer.");
    type = kind === "luma_inverted" ? TrackMatteType.LUMA_INVERTED
         : kind === "alpha" ? TrackMatteType.ALPHA
         : kind === "alpha_inverted" ? TrackMatteType.ALPHA_INVERTED
         : TrackMatteType.LUMA;
    layer.setTrackMatte(matte, type);
  }
  return { imported: item.name, matte_layer: matte.index,
           target_layer: layer.index, matte: kind };
};

// ------------------------------------------------------ music / beats
// Markers, expression-control sliders and expressions are the plumbing
// that lets keyframed beat data drive any property in the comp.
function CA_findLayer(comp, name) {
  var i;
  for (i = 1; i <= comp.numLayers; i++) if (comp.layer(i).name === name) return comp.layer(i);
  return null;
}

CA_TOOLS.find_layer = function (a) {
  var comp = CA_comp(a.comp);
  var l = CA_findLayer(comp, String(a.name));
  return { comp: comp.name, name: a.name, index: l ? l.index : null };
};

CA_TOOLS.list_layers = function (a) {
  var comp = CA_comp(a.comp);
  var out = { comp: comp.name, width: comp.width, height: comp.height,
              fps: comp.frameRate, duration_s: comp.duration, layers: [] };
  var i, l, src, kind, file, hasAudio, hasVideo;
  for (i = 1; i <= comp.numLayers; i++) {
    l = comp.layer(i);
    src = null; file = null; kind = "layer"; hasAudio = false; hasVideo = false;
    try { src = l.source; } catch (e) { src = null; }
    try { hasAudio = !!l.hasAudio; } catch (e1) {}
    try { hasVideo = !!l.hasVideo; } catch (e2) {}
    if (l.nullLayer) kind = "null";
    else if (src && src instanceof CompItem) kind = "comp";
    else if (src && src.mainSource && src.mainSource instanceof SolidSource) kind = "solid";
    else if (l instanceof TextLayer) kind = "text";
    else if (src) kind = hasVideo ? "footage" : "audio";
    if (src && src.mainSource) { try { if (src.mainSource.file) file = src.mainSource.file.fsName; } catch (e3) {} }
    out.layers.push({ index: i, name: l.name, kind: kind, has_audio: hasAudio,
      has_video: hasVideo, in_s: l.inPoint, out_s: l.outPoint, start_s: l.startTime,
      guide: !!l.guideLayer, source: src ? src.name : null, file: file });
  }
  return out;
};

// Remove layers by name. Each entry of a.names is either a plain name —
// the TOPMOST layer of that name goes (BEAT and FLASH solids are added at
// the top; all_matches:true removes every one) — or {name, index, start_s}
// for a layer known by identity: the layer at index goes if its name (and
// startTime, when given) match, else the BOTTOM-most layer with that name
// and startTime (add_clip appends clips at the bottom). A name that matches
// nothing is reported in missed, and nothing else is touched.
CA_TOOLS.remove_layers = function (a) {
  var comp = CA_comp(a.comp);
  var i, j, l, e, name, idx, hit, removed = [], missed = [], names = a.names || [], all = !!a.all_matches;
  for (j = 0; j < names.length; j++) {
    e = names[j];
    if (e && typeof e === "object") {
      name = String(e.name);
      idx = Number(e.index);
      hit = null;
      if (idx >= 1 && idx <= comp.numLayers) {
        l = comp.layer(idx);
        if (l.name === name && (e.start_s === undefined || e.start_s === null || Math.abs(l.startTime - Number(e.start_s)) < 0.01)) hit = l;
      }
      if (!hit) {
        for (i = comp.numLayers; i >= 1; i--) {
          l = comp.layer(i);
          if (l.name === name && (e.start_s === undefined || e.start_s === null || Math.abs(l.startTime - Number(e.start_s)) < 0.01)) { hit = l; break; }
        }
      }
      if (hit) { removed.push(hit.name); hit.remove(); } else missed.push(name);
      continue;
    }
    name = String(e);
    hit = null;
    for (i = 1; i <= comp.numLayers; i++) {
      l = comp.layer(i);
      if (l.name === name) {
        hit = l; removed.push(l.name); l.remove();
        if (!all) break;
        i--;
      }
    }
    if (!hit) missed.push(name);
  }
  return { comp: comp.name, removed: removed, missed: missed };
};

CA_TOOLS.set_markers = function (a) {
  var comp = CA_comp(a.comp);
  var target = (a.layer !== undefined && a.layer !== null)
    ? CA_layer(comp, a.layer).property("ADBE Marker") : comp.markerProperty;
  var i, m, mv, n = 0;
  if (a.clear_prefix) {
    for (i = target.numKeys; i >= 1; i--) {
      mv = target.keyValue(i);
      if (String(mv.comment).indexOf(String(a.clear_prefix)) === 0) target.removeKey(i);
    }
  }
  for (i = 0; i < (a.markers || []).length; i++) {
    m = a.markers[i];
    mv = new MarkerValue(String(m.comment || ""));
    if (m.duration) mv.duration = Number(m.duration);
    target.setValueAtTime(Number(m.t), mv);
    n += 1;
  }
  return { comp: comp.name, layer: a.layer === undefined ? null : a.layer,
           added: n, total: target.numKeys };
};

// A Slider Control effect named effect_name on the layer, with keys
// [[t, v], ...] set in one go (append=true adds to what is there).
CA_TOOLS.set_slider_keys = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var fx = layer.property("ADBE Effect Parade");
  var eff = fx.property(String(a.effect_name)), slider, i, times = [], vals = [];
  if (!eff) { eff = fx.addProperty("ADBE Slider Control"); eff.name = String(a.effect_name); }
  slider = eff.property("ADBE Slider Control-0001") || eff.property(1);
  if (!a.append) while (slider.numKeys > 0) slider.removeKey(1);
  if (a.keys && a.keys.length) {
    for (i = 0; i < a.keys.length; i++) { times.push(Number(a.keys[i][0])); vals.push(Number(a.keys[i][1])); }
    slider.setValuesAtTimes(times, vals);
    if (a.hold)
      for (i = 1; i <= slider.numKeys; i++)
        slider.setInterpolationTypeAtKey(i, KeyframeInterpolationType.HOLD, KeyframeInterpolationType.HOLD);
  } else if (a.value !== undefined) {
    slider.setValue(Number(a.value));
  }
  return { layer: layer.name, effect: eff.name, keys: slider.numKeys };
};

CA_TOOLS.set_expression = function (a) {
  var comp = CA_comp(a.comp);
  var layer = CA_layer(comp, a.layer);
  var prop = layer, i;
  for (i = 0; i < a.path.length; i++) {
    prop = prop.property(a.path[i]);
    if (!prop) CA_err("No property '" + a.path[i] + "' at depth " + i + ".");
  }
  if (prop.canSetExpression === false) CA_err("'" + prop.name + "' cannot take an expression.");
  prop.expression = (a.expression === null || a.expression === undefined) ? "" : String(a.expression);
  return { layer: layer.name, property: prop.name,
           enabled: !!prop.expressionEnabled, error: prop.expressionError || "" };
};

CA_TOOLS.add_null = function (a) {
  var comp = CA_comp(a.comp);
  var l = comp.layers.addNull(comp.duration);
  l.name = a.name || "Null";
  if (a.guide) l.guideLayer = true;
  if (a.shy) l.shy = true;
  return { layer: l.index, name: l.name };
};

// A solid the size of the comp; above_layer puts it right above that layer
// (resolved BEFORE adding, since adding shifts every index by one).
CA_TOOLS.add_solid = function (a) {
  var comp = CA_comp(a.comp);
  var above = (a.above_layer !== undefined && a.above_layer !== null) ? CA_layer(comp, a.above_layer) : null;
  var c = a.color || [1, 1, 1];
  var l = comp.layers.addSolid([Number(c[0]), Number(c[1]), Number(c[2])], a.name || "Solid",
                               comp.width, comp.height, comp.pixelAspect || 1, comp.duration);
  if (above) l.moveBefore(above);
  if (a.adjustment) l.adjustmentLayer = true;
  if (a.blend === "add") l.blendingMode = BlendingMode.ADD;
  else if (a.blend === "screen") l.blendingMode = BlendingMode.SCREEN;
  if (a.start_s !== undefined) l.inPoint = Number(a.start_s);
  if (a.end_s !== undefined) l.outPoint = Number(a.end_s);
  if (a.opacity !== undefined)
    l.property("ADBE Transform Group").property("ADBE Opacity").setValue(Number(a.opacity));
  return { layer: l.index, name: l.name };
};

function CA_invoke(name, argsJson) {
  var args, out;
  try {
    args = argsJson ? eval("(" + argsJson + ")") : {};
    if (!CA_TOOLS[name]) CA_err("Unknown host tool: " + name);
    app.beginUndoGroup("Claude: " + name);
    try { out = CA_TOOLS[name](args); }
    finally { app.endUndoGroup(); }
    return CA_str({ ok: true, data: out });
  } catch (e) {
    return CA_str({ ok: false, error: e.message || String(e) });
  }
}
