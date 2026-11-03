// What can this app's Node do about the two step-6 problems?
//
// Neither answer may be assumed. The report has to say which zstd surface the
// runtime actually provides, and what the app's `Date` and `Intl` report, from
// inside the app process rather than from a host Node.
//
// Gated by DSHPORTE_STEP6_PROBE=1 from sim/ios-app-entry.mjs.
import { writeFileSync } from 'node:fs';
import zlib from 'node:zlib';

const home = process.env.DSH_HOME ?? '.';
const out = { at: new Date().toISOString(), node: process.version, zlib: {}, local: {} };

// ------------------------------------------------------------------- 1. zstd
const plain = Buffer.from(JSON.stringify({ type: 'session', version: 4, probe: 'zstd' }) + '\n', 'utf8');
out.zlib.names = {
  zstdCompressSync: typeof zlib.zstdCompressSync,
  zstdDecompressSync: typeof zlib.zstdDecompressSync,
  zstdCompress: typeof zlib.zstdCompress,
  createZstdCompress: typeof zlib.createZstdCompress,
  createZstdDecompress: typeof zlib.createZstdDecompress,
  ZSTD_c_checksumFlag: zlib.constants && zlib.constants.ZSTD_c_checksumFlag,
};
try {
  const frame = zlib.zstdCompressSync(plain, { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } });
  const back = zlib.zstdDecompressSync(frame);
  out.zlib.roundTrip = {
    ok: back.equals(plain),
    frameBytes: frame.length,
    magic: frame.subarray(0, 4).toString('hex'),
    // The descriptor byte tells the reader which frame fields follow; DSH's own
    // scanner reads it, so recording it proves the frame is in the shape DSH
    // already parses rather than merely decodable by this one API.
    descriptor: frame[4],
    checksumBit: (frame[4] & 4) !== 0,
    singleSegment: (frame[4] & 32) !== 0,
    contentSizeFlag: frame[4] >>> 6,
  };
} catch (error) {
  out.zlib.roundTrip = { ok: false, error: String(error && error.message) };
}
// A hand-built RAW-block frame: the fallback that needs no compressor at all.
try {
  out.zlib.rawBlock = (() => {
    const body = plain;
    const header = Buffer.alloc(4 + 1 + 1 + 3);
    header.writeUInt32LE(0xfd2fb528, 0);          // zstd magic, little endian
    header[4] = 0x20 | ((body.length >= 256 ? 2 : 1) << 6); // single-segment, content size
    header[5] = body.length;                        // content size, 1 byte (single-segment)
    // block header: last=1, type=0 (raw), size = body.length
    const blockHeader = (1 | (0 << 1) | (body.length << 3)) >>> 0;
    header.writeUIntLE(blockHeader, 6, 3);
    const frame = Buffer.concat([header.subarray(0, 9), body]);
    const back = zlib.zstdDecompressSync(frame);
    return { ok: back.equals(plain), bytes: frame.length };
  })();
} catch (error) {
  out.zlib.rawBlock = { ok: false, error: String(error && error.message) };
}

// --------------------------------------------------------------- 2. local time
const fixed = new Date(1793179717698); // 2026-10-28T09:28:37.698Z
out.local = {
  tzEnv: process.env.TZ ?? null,
  getTimezoneOffset: new Date().getTimezoneOffset(),
  fixedOffset: fixed.getTimezoneOffset(),
  fixedHour: fixed.getHours(),
  fixedToString: fixed.toString(),
  intlTimeZone: (() => {
    try { return new Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (error) { return 'ERROR: ' + error.message; }
  })(),
  // The zone the shell clock and the model-visible stamp must agree with.
  deviceZoneFromTimezoneName: new Intl.DateTimeFormat().resolvedOptions().timeZone,
};

writeFileSync(`${home}/DSHPortE-step6-probe.json`, JSON.stringify(out, null, 2));
console.log('DSHPORTE_STEP6_PROBE ' + JSON.stringify(out));
