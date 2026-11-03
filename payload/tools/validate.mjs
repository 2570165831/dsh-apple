import { validateStoredEvents, assertVersion } from '@deepseek-ai/dsh-session-persistence';
import { execFileSync } from 'node:child_process';
const text = execFileSync('zstd', ['-dc', '--', process.argv[2]], { maxBuffer: 1 << 30 }).toString('utf8');
const lines = text.split('\n').filter(Boolean).map(l => JSON.parse(l));
const meta = lines[0]; const events = lines.slice(1);
try { assertVersion(meta); validateStoredEvents(meta, events); console.log('VALID', events.length, 'events'); }
catch (e) { console.log('INVALID:', String(e.message).slice(0, 400)); }
