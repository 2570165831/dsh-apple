#!/usr/bin/env node
// Check every code point against the host's original Unicode property tables.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const data = JSON.parse(readFileSync(new URL('./unicode-property-ranges.json', import.meta.url)));
assert.equal(process.versions.unicode, data.unicodeVersion,
  'use the generator host Unicode version when verifying these pinned tables');
const codePointCount = 0x10ffff + 1;
let checked = 0;
for (const [property, ranges] of Object.entries(data.classes)) {
  const upstream = new RegExp(`^\\p{${property}}$`, 'u');
  const patched = new RegExp(`^[${ranges}]$`, 'u');
  for (let point = 0; point < codePointCount; point++) {
    const character = String.fromCodePoint(point);
    assert.equal(patched.test(character), upstream.test(character),
      `${property}: U+${point.toString(16)}`);
  }
  checked++;
}
const { formats } = await import('../payload/node_modules/@earendil-works/pi-schema/dist/formats/index.js');
const fixtures = [
  ['idn-email', 'hello@example.com', true],
  ['idn-email', '用户@例子.中国', true],
  ['idn-email', 'a@-example.com', false],
  ['idn-email', 'a@exam_ple.com', false],
  ['idn-hostname', 'example.com', true],
  ['idn-hostname', '例子.中国', true],
  ['idn-hostname', '-example.com', false],
  ['idn-hostname', 'exam_ple.com', false],
];
for (const [format, value, expected] of fixtures) assert.equal(formats[format](value), expected, `${format}: ${value}`);
console.log(`${checked} Unicode classes x ${codePointCount} code points and ${fixtures.length} IDN format cases passed`);
