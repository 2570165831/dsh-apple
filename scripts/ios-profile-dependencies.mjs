// Source audit only: candidates for provided services are not proof of activation.
// Keep browser/device boot acceptance separate from this dependency check.
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import yaml from '../payload/node_modules/js-yaml/index.js';
import { composeEntries } from '../payload/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js';
import { buildOverlay } from '../sim/safe-mode.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const packages = join(root, 'payload/node_modules/@deepseek-ai');
const schema = yaml.JSON_SCHEMA.extend(new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar', construct: (source) => ({ __jsExpr: source }),
}));
const read = (path) => readFileSync(path, 'utf8');
const parse = (path) => yaml.load(read(path), { schema });
const manifest = (path) => JSON.parse(read(join(path, 'package.json')));

export function profileRows({ safe = false, mock = false, restoreEntry = false } = {}) {
  const layers = [];
  for (const bundle of manifest(join(root, 'profiles/ios-sim')).dsh.profile.bundles) {
    if (bundle === 'dsh-ios-profile') {
      layers.push(parse(join(root, 'profiles/ios-sim/cordis.patch.yml')));
    } else {
      const path = join(root, 'payload/node_modules', bundle);
      const patches = manifest(path).dsh.bundle.patch;
      for (const patch of [patches].flat()) layers.push(parse(join(path, patch)));
    }
  }
  if (restoreEntry) layers.push([{ id: 'entry-customization', disabled: false }]);
  if (safe) layers.push(yaml.load(buildOverlay(), { schema }));
  const warnings = [];
  const rows = composeEntries(layers, (warning) => warnings.push(warning));
  const env = mock ? { DSHPORTC_MOCK_PORT: '19700' } : {};
  const disabled = (value) => typeof value === 'object' && value?.__jsExpr
    ? runInNewContext(value.__jsExpr, {
      process: { platform: 'darwin', env },
      ctx: { get: (key) => key === 'profileContext' ? { name: 'ios-sim' } : undefined },
    }, { timeout: 1000 }) : value;
  const flatten = (items) => items.flatMap((row) => [
    { ...row, disabled: !!disabled(row.disabled) },
    ...(row.group && !disabled(row.disabled) ? flatten(row.config) : []),
  ]);
  return { rows: flatten(rows), warnings };
}

function browserExport(value) {
  if (typeof value === 'string') return value;
  if (!value) return undefined;
  return browserExport(value?.browser ?? value?.default);
}

export function clientSources() {
  return readdirSync(packages).flatMap((name) => {
    const path = join(packages, name);
    if (!existsSync(join(path, 'package.json'))) return [];
    const pkg = manifest(path);
    if (pkg.dsh?.client?.platform !== 'web') return [];
    const entry = browserExport(pkg.exports?.['./client']);
    assert.ok(entry, `${name} has no browser export`);
    const source = read(join(path, entry));
    const exported = [...source.matchAll(/exports\.inject = ([^;]+);/g)];
    assert.ok(exported.length <= 1, `${name}: ambiguous exported inject`);
    let inject = [];
    if (exported.length) {
      assert.equal(exported[0][1], 'inject', `${name}: inspect new inject form`);
      const defs = [...source.matchAll(/const inject = (\[[\s\S]*?\]);/g)];
      assert.equal(defs.length, 1, `${name}: inspect new inject definition`);
      inject = JSON.parse(defs[0][1]);
    } else {
      // Current Shortcuts service exports its injection gate on a class.
      assert.equal(pkg.name, '@deepseek-ai/dsh-client-shortcuts');
      const defs = [...source.matchAll(/static inject = (\[[\s\S]*?\]);/g)];
      assert.equal(defs.length, 1, `${name}: inspect class inject`);
      inject = JSON.parse(defs[0][1]);
    }
    assert.ok(inject.every((key) => typeof key === 'string'));
    const provides = [...source.matchAll(
      /(?:\b\w+\.(?:reflect\.)?provide\(|\bsuper\(ctx,\s*)"([^"]+)"/g,
    )].map((match) => match[1]);
    // Remote namespaces are mounted from generated descriptors, independently
    // of backend availability. An RPC can still fail when a host is disabled.
    const remotes = [...source.matchAll(/"([\w]+)\/[\w]+": \{\s*service: /g)]
      .map((match) => `remote.${match[1]}`);
    const nestedInject = [...source.matchAll(/ctx\.inject\((\[[\s\S]*?\]),/g)]
      .map((match) => Array.from(runInNewContext(match[1], { inject }, { timeout: 1000 })));
    return [{ name: pkg.name, inject, nestedInject, provides: [...new Set(provides)],
      remotes: [...new Set(remotes)], moduleInject: pkg.dsh.client.inject ?? [] }];
  });
}

export function auditProfile(options = {}) {
  const { rows, warnings } = profileRows(options);
  const clients = clientSources();
  const names = new Set(rows.filter((row) => !row.disabled).map((row) => row.name));
  const active = clients.filter((client) => names.has(client.name));
  // loader is installed by the browser kernel before the roster is activated.
  const services = new Set(['loader', ...active.flatMap((c) => [...c.provides, ...c.remotes])]);
  const missing = active.flatMap((client) => client.inject
    .filter((key) => !services.has(key)).map((service) => ({ package: client.name, service })));
  const nestedMissing = active.flatMap((client) => client.nestedInject.flat()
    .filter((key) => !services.has(key)).map((service) => ({ package: client.name, service })));
  const inactive = clients.filter((client) => !names.has(client.name));
  const unavailable = new Set(inactive.flatMap((client) => client.provides)
    .filter((key) => !services.has(key)));
  const affected = clients.flatMap((client) => [...new Set([
    ...client.inject, ...client.nestedInject.flat(),
  ])].filter((key) => unavailable.has(key)).map((service) => ({
    package: client.name, service, active: names.has(client.name),
  })));
  const disabledHostNamespaces = parse(join(root, 'profiles/ios-sim/cordis.patch.yml'))
    .filter((patch) => patch.disabled === true).flatMap((patch) => {
      const row = rows.find((item) => item.id === patch.id);
      const pkg = row?.name?.match(/^(@[^/]+\/[^/]+)/)?.[1];
      if (!pkg) return [];
      const path = join(root, 'payload/node_modules', pkg, 'lib/typert.remote-client.js');
      if (!existsSync(path)) return [];
      const namespaces = [...new Set([...read(path).matchAll(
        /["'](\w+)\/\w+["']: \{\s*service: ["']([^"']+)["']/g,
      )].map((match) => match[1]))];
      return [{ id: row.id, namespaces, consumers: clients.flatMap((client) =>
        [...new Set([...client.inject, ...client.nestedInject.flat()])]
          .filter((key) => namespaces.some((ns) => key === `remote.${ns}`))
          .map((service) => ({ package: client.name, service, active: names.has(client.name),
            required: client.inject.includes(service) }))) }];
    });
  return { warnings, rows: rows.map(({ id, name, disabled }) => ({ id, name, disabled })),
    clientsScanned: clients.length, activeClients: active.length, missing, nestedMissing, affected,
    disabledHostNamespaces, clients };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { clients, ...normal } = auditProfile();
  const { clients: safeClients, ...safe } = auditProfile({ safe: true });
  console.log(JSON.stringify({ kind: 'static source audit; not browser activation', clients, normal, safe }, null, 2));
  if (normal.missing.length || safe.missing.length) process.exitCode = 1;
}
