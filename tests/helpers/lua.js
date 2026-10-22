'use strict';
// Companion tests run the shipped Lua against untouched stock Polestar 0.2.5.
// Old viewer regression cases retain their module lists as scenario descriptions;
// the companion always loads from its complete TOC, through a separate namespace.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawnSync} = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const PROJECT = path.dirname(ROOT);
const STOCK = process.env.POLESTAR_STOCK_DIR;
if (!STOCK) throw new Error('Set POLESTAR_STOCK_DIR to a Polestar 0.2.6 source/test fixture');
const ADDONS = path.join(ROOT, 'addon');
const STUBS = path.join(ROOT, 'tests/lua');
const norm = p => p.replace(/\\/g, '/');
const quote = s => '"' + norm(String(s)).replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';

function xmlFiles(file) {
  const text = fs.readFileSync(file, 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const out = [];
  for (const match of text.matchAll(/<(Script|Include)\s+file\s*=\s*"([^"]+)"\s*\/?>/g)) {
    const target = path.join(path.dirname(file), norm(match[2]));
    if (target.endsWith('.xml')) out.push(...xmlFiles(target)); else out.push(target);
  }
  return out;
}
function expand(dir, entries) {
  return entries.flatMap(entry => {
    const target = path.join(dir, norm(entry));
    return target.endsWith('.xml') ? xmlFiles(target) : [target];
  });
}
function tocEntries(dir) {
  return fs.readFileSync(path.join(dir, path.basename(dir) + '.toc'), 'utf8').split(/\r?\n/)
    .map(s => s.trim()).filter(s => s && !s.startsWith('#'));
}
function dirFiles(dir) { return expand(dir, tocEntries(dir)); }
function tocFiles(name) { return dirFiles(path.join(ADDONS, name)); }
function findLua() {
  if (process.env.LUA) return process.env.LUA;
  const runtime = path.join(PROJECT, 'runtime/runtime.json');
  if (fs.existsSync(runtime)) return JSON.parse(fs.readFileSync(runtime, 'utf8')).lua;
  return 'lua5.1';
}

function runAddon(opts = {}) {
  const lines = [
    `package.path = ${quote(path.join(STOCK, 'tests/lua/?.lua;'))} .. package.path`,
    `dofile(${quote(path.join(STOCK, 'tests/lua/wow_stub.lua'))})`,
  ];
  for (const stub of opts.stubs || []) {
    const local = path.join(STUBS, stub);
    lines.push(`dofile(${quote(fs.existsSync(local) ? local : path.join(STOCK, 'tests/lua', stub))})`);
  }
  if (opts.before) lines.push(opts.before);
  lines.push(`local function __load(name, files, saved)
    local ns = {}
    for _, file in ipairs(files) do assert(loadfile(file))(name, ns) end
    if saved then saved() end
    stub.addonLoaded(name)
    return ns
  end`);
  const requested = (opts.addons || []).flatMap(a => typeof a === 'object' ? a.files || [] : []);
  const stockDir = path.join(STOCK, 'addon/Polestar');
  const entries = opts.stockFiles || ['Core/Core.xml', 'Theme/Theme.xml', 'UI/UI.lua'];
  if (!opts.stockFiles && requested.includes('Nav/Nav.lua')) entries.push('Nav/Nav.lua');
  const stockFiles = opts.fullCore ? dirFiles(stockDir) : expand(stockDir, entries);
  const load = (name, files, saved) => lines.push(`__load(${quote(name)}, {${files.map(quote).join(',')}}, ${saved ? `function() ${saved} end` : 'nil'})`);
  if (opts.loadCore !== false) load('Polestar', stockFiles, opts.saved && opts.saved.Polestar);
  if (opts.between) lines.push(opts.between);
  load('Polestar_Planner', tocFiles('Polestar_Planner'), opts.saved && opts.saved.Polestar_Planner);
  if (opts.login) lines.push('stub.login()');
  if (opts.script) lines.push(opts.script);
  const file = path.join(os.tmpdir(), `polestar-planner-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.lua`);
  fs.writeFileSync(file, lines.join('\n'));
  try {
    const result = spawnSync(findLua(), [file], {encoding:'utf8', cwd:ROOT, maxBuffer:64 * 1024 * 1024});
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`Lua failed (exit ${result.status}):\n${result.stderr}\n${result.stdout}`);
    return {emitted:result.stdout.split('\n').filter(s => s.startsWith('@@JSON ')).map(s => JSON.parse(s.slice(7))),
      stdout:result.stdout, stderr:result.stderr};
  } finally { fs.rmSync(file, {force:true}); }
}
module.exports = {runAddon, ROOT, STOCK, ADDONS, tocEntries, tocFiles, dirFiles, xmlFiles};
