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
  tmp.layers.add(src);
  var f = new File(CA_grabDir().fsName + "/source_" + new Date().getTime() + ".png");
  if (typeof tmp.saveFrameToPng !== "function") {
    tmp.remove();
    CA_err("saveFrameToPng is missing in this AE version.");
  }
  tmp.saveFrameToPng(Math.min(t, dur), f);
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
      fx = group.property(base) || (known[base] ? group.property(known[base]) : null);
      if (!fx) fx = group.addProperty(known[base] || base);
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
