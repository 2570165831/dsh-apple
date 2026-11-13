import assert from 'node:assert/strict';
import { test } from 'node:test';
import { auditProfile } from '../../scripts/ios-profile-dependencies.mjs';

const entry = '@deepseek-ai/dsh-client-ui-entry-customization';
const manager = '@deepseek-ai/dsh-client-ui-plugin-manager';

test('the audit detects the rc.5 pluginNavigation regression before the profile fix', () => {
  assert.deepEqual(auditProfile({ restoreEntry: true }).missing, [
    { package: entry, service: 'pluginNavigation' },
  ]);
});

for (const safe of [false, true]) {
  for (const mock of [false, true]) {
    test(`iOS frontend dependencies: safe=${safe}, mock=${mock}`, () => {
      const result = auditProfile({ safe, mock });
      assert.deepEqual(result.missing, [], 'a browser plugin would wait for an absent service');
      assert.deepEqual(result.nestedMissing, [], 'review an optional injection waiting for an absent service');
      assert.ok(result.affected.every((consumer) => !consumer.active),
        'a consumer of a disabled frontend service is still enabled');
      for (const id of ['plugin-manager', 'tool-plugin-manager', 'ui-plugin-manager', 'entry-customization']) {
        assert.equal(result.rows.find((row) => row.id === id)?.disabled, true, id);
      }
      for (const id of ['ui-sidebar', 'ui-conversation', 'ui-sidebar-right', 'ui-chat', 'ui-trajectory']) {
        assert.equal(result.rows.find((row) => row.id === id)?.disabled, false, id);
      }
      // These stale upstream ids predate this fix; any new skipped patch is an error.
      assert.deepEqual(result.warnings, [
        'patch: entry "usage-report" not found',
        'patch: entry "anonymous-user-id" not found',
        'patch: entry "time-context" not found',
      ]);
    });
  }
}

test('all pluginNavigation consumers stay outside the iOS roster', () => {
  const result = auditProfile();
  assert.deepEqual(result.affected.filter((item) => item.service === 'pluginNavigation'), [
    { package: entry, service: 'pluginNavigation', active: false },
    { package: '@deepseek-ai/dsh-experimental-client-ui-voice-input',
      service: 'pluginNavigation', active: false },
  ]);
  const plugin = result.clients.find((client) => client.name === entry);
  assert.ok(plugin.inject.includes('pluginNavigation'), 'review the upstream dependency if it changes');
  const provider = result.clients.find((client) => client.name === manager);
  for (const service of ['remote.pluginManager', 'remote.pluginInventory', 'remote.pluginRegistryProbe']) {
    assert.ok(provider.inject.includes(service));
  }
});
