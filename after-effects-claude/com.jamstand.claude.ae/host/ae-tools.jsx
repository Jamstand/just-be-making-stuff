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
  if (a.in_s !== undefined) layer.inPoint = Number(a.in_s);
  if (a.out_s !== undefined) layer.outPoint = Number(a.out_s);
  if (a.start_s !== undefined)
    layer.startTime = Number(a.start_s) - (Number(a.in_s) || 0);
  layer.moveToEnd();       // append order: new clips go under existing ones
  return { layer: comp.numLayers, name: layer.name,
           in_s: layer.inPoint, out_s: layer.outPoint,
           comp_start_s: layer.inPoint + layer.startTime - layer.inPoint };
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

CA_TOOLS.grab_frame = function (a) {
  var comp = CA_comp(a.comp);
  var t = a.time_s !== undefined ? Number(a.time_s) : comp.time;
  var dir = new Folder(Folder.userData.fsName + "/ClaudeAssistantAE");
  if (!dir.exists) dir.create();
  var f = new File(dir.fsName + "/frame_" + new Date().getTime() + ".png");
  if (typeof comp.saveFrameToPng !== "function")
    CA_err("saveFrameToPng is missing in this AE version — frame export "
           + "needs the render-queue fallback (not yet built).");
  comp.saveFrameToPng(t, f);
  // Undocumented API writes asynchronously since CC2015: poll.
  var waited = 0;
  while (!f.exists && waited < 5000) { $.sleep(200); waited += 200; }
  if (!f.exists) CA_err("saveFrameToPng produced no file within 5s.");
  return { file: f.fsName, time_s: t, comp: comp.name };
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
