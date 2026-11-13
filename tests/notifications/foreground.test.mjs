// Source guards for the native notification gates; system presentation needs iOS.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/DSHPortC/NotificationBridge.swift', import.meta.url), 'utf8');

function section(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing native section: ${start}`);
  return source.slice(from, to);
}

test('foreground decisions read all connected scenes instead of a cached transition', () => {
  const state = section('private var sceneIsActive:', '/// The system\'s answer about authorization');
  assert.match(state, /let scenes = app\.connectedScenes/);
  assert.match(state, /scenes\.isEmpty\s*\? app\.applicationState == \.active\s*: scenes\.contains \{ \$0\.activationState == \.foregroundActive \}/);
  assert.doesNotMatch(source, /sceneIsActive\s*=/);
  assert.match(source, /UIScene\.didActivateNotification/);
  assert.match(source, /UIScene\.willDeactivateNotification/);
  const delivery = section('private func deliver(', 'private func post(');
  assert.match(delivery, /guard !sceneIsActive else \{\s*suppress\(/);
});

test('the presentation delegate rechecks on the main actor before completing', () => {
  const delegate = section('willPresent notification:', 'didReceive response:');
  assert.match(delegate, /Task \{ @MainActor in\s*completionHandler\(NotificationBridge\.shared\.presentationOptions\(for: notification\)\)/);
  assert.doesNotMatch(delegate, /completionHandler\(\[\.banner, \.sound\]\)/);
});

test('foreground presentation is recorded and silent while background keeps banner and sound', () => {
  const presentation = section('func presentationOptions(', '/// The three gates');
  assert.match(presentation, /report\.lastSceneActive = sceneIsActive/);
  assert.match(presentation, /guard !sceneIsActive else \{/);
  assert.match(presentation, /let info = notification\.request\.content\.userInfo/);
  for (const key of ['kind', 'sessionId', 'key']) {
    assert.ok(presentation.includes(`${key}: info["${key}"] as? String ?? ""`));
  }
  assert.match(presentation, /suppress\([\s\S]*reason: "App 在前台，不发"\s*\)\s*return \[\]\s*\}\s*return \[\.banner, \.sound\]/);
  const suppression = section('private func suppress(', '// MARK: - Foreground state');
  assert.match(suppression, /report\.suppressed\.append\(/);
  assert.match(suppression, /emit\("dshportc: notify suppressed/);
  assert.match(suppression, /writeReport\(\)/);
});
