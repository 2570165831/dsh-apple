#!/usr/bin/env node
// Regenerate the static Unicode classes used by the no-ICU pi-schema patch.
// Run with the ICU-enabled host Node; never needed by the app at runtime.
import { writeFileSync } from 'node:fs';
const properties = ['ASCII', 'L', 'N', 'Mn', 'Mc', 'Me', 'Nd', 'Script=Greek',
  'Script=Hebrew', 'Script=Hiragana', 'Script=Katakana', 'Script=Han',
  'Script=Arabic', 'Script=Syriac', 'Script=Thaana', 'Script=Mandaic'];
const classes = {};
const escape = (point) => `\\u{${point.toString(16)}}`;
for (const property of properties) {
  const regex = new RegExp(`^\\p{${property}}$`, 'u');
  const ranges = [];
  let start = -1;
  for (let point = 0; point <= 0x110000; point++) {
    const matches = point <= 0x10ffff && regex.test(String.fromCodePoint(point));
    if (matches && start < 0) start = point;
    if (!matches && start >= 0) {
      ranges.push(escape(start) + (point - 1 === start ? '' : '-' + escape(point - 1)));
      start = -1;
    }
  }
  classes[property] = ranges.join('');
}
const data = { unicodeVersion: process.versions.unicode, classes };
writeFileSync(new URL('./unicode-property-ranges.json', import.meta.url),
  JSON.stringify(data, null, 2) + '\n');
console.log(`Generated ${properties.length} static classes from Unicode ${data.unicodeVersion}`);
