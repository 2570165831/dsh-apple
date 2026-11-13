// Built-app acceptance only; no bundle paths means these tests are skipped.

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const debugApp = process.env.DSH_DEBUG_APP;
const releaseApp = process.env.DSH_RELEASE_APP;
const debugOnly = { skip: debugApp ? false : 'set DSH_DEBUG_APP to a built Debug .app' };
const releaseOnly = { skip: releaseApp ? false : 'set DSH_RELEASE_APP to a Release or Archive .app' };

function plist(path) {
  return JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', path], {
    encoding: 'utf8',
  }));
}

function executablePath(app) {
  const info = plist(join(app, 'Info.plist'));
  return join(app, info.CFBundleExecutable);
}

function reasons(app) {
  const manifest = plist(join(app, 'PrivacyInfo.xcprivacy'));
  return new Map(manifest.NSPrivacyAccessedAPITypes.map((entry) => [
    entry.NSPrivacyAccessedAPIType, entry.NSPrivacyAccessedAPITypeReasons,
  ]));
}

// Long strings survive linker symbol stripping.
const internalMarkers = [
  'triggerKernelDieForTesting',
  'dshportc acceptance test: deliberate kernel die()',
  'DSHPORTE_PROBE_MODE',
  'DSHPORTE_POWER_LOG',
];

test('Debug retains the internal hooks as a positive control', debugOnly, () => {
  const executable = executablePath(debugApp);
  const debugDylib = `${executable}.debug.dylib`;
  const binary = Buffer.concat([
    readFileSync(executable),
    existsSync(debugDylib) ? readFileSync(debugDylib) : Buffer.alloc(0),
  ]);
  for (const marker of internalMarkers) {
    assert.ok(binary.includes(Buffer.from(marker)), `Debug is missing ${marker}`);
  }
});

test('Release excludes fault injection and device measurement hooks', releaseOnly, () => {
  const executable = executablePath(releaseApp);
  assert.ok(!existsSync(`${executable}.debug.dylib`), 'Release contains a debug dylib');
  const binary = readFileSync(executable);
  for (const marker of internalMarkers) {
    assert.ok(!binary.includes(Buffer.from(marker)), `Release still contains ${marker}`);
  }
});

test('Release bundles the source-audited API declarations', releaseOnly, () => {
  const manifest = plist(join(releaseApp, 'PrivacyInfo.xcprivacy'));
  assert.equal(manifest.NSPrivacyTracking, false);
  assert.deepEqual(manifest.NSPrivacyTrackingDomains, []);
  assert.deepEqual(manifest.NSPrivacyCollectedDataTypes, []);
  const declared = reasons(releaseApp);
  assert.ok(declared.get('NSPrivacyAccessedAPICategoryUserDefaults')?.includes('CA92.1'));
  assert.ok(declared.get('NSPrivacyAccessedAPICategoryFileTimestamp')?.includes('C617.1'));
  assert.ok(declared.get('NSPrivacyAccessedAPICategorySystemBootTime')?.includes('35F9.1'));
  // The rootfs installer checks free space before an import (ISHRootfsInstaller).
  assert.ok(declared.get('NSPrivacyAccessedAPICategoryDiskSpace')?.includes('E174.1'));
});

test('Release declares clock and disk APIs referenced by its binaries', releaseOnly, () => {
  // Symbol presence identifies a category, not an approved reason for using it.
  const categories = [
    ['NSPrivacyAccessedAPICategorySystemBootTime', ['_mach_absolute_time']],
    ['NSPrivacyAccessedAPICategoryDiskSpace', [
      '_statfs', '_fstatfs', '_statvfs', '_fstatvfs',
    ]],
  ];
  const declared = reasons(releaseApp);
  const missing = [];
  for (const path of [
    executablePath(releaseApp),
    join(releaseApp, 'Frameworks', 'NodeMobile.framework', 'NodeMobile'),
  ]) {
    assert.ok(existsSync(path), `Missing binary for API audit: ${path}`);
    const symbols = execFileSync('nm', ['-u', path], { encoding: 'utf8' }).split(/\s+/);
    for (const [category, names] of categories) {
      const used = names.filter((name) => symbols.some((symbol) =>
        symbol === name || symbol.startsWith(name + '$')));
      if (used.length && !declared.get(category)?.length) {
        missing.push({ path, category, symbols: used });
      }
    }
  }
  assert.deepEqual(missing, [], 'Audit these call sites and declare their actual approved reasons');
});
