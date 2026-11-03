// `dsh-attachment-ios`: DSH's attachment store with the raster work done by the
// platform's own image stack instead of `sharp`.
//
// WHY A PROVIDER AND NOT A PATCH: `ctx.attachments` is a cordis *service*, and
// `@deepseek-ai/dsh-attachment-local` provides it. Every consumer — the prompt
// admission path, `read_image`, `fileUploads`, the session projection that
// advertises `imageLimits` to the browser — talks to the service, never to the
// package. Replacing the one row that provides it therefore swaps the image
// implementation with no change to any consumer. That is the same structural
// argument PATCHES.md P-6 makes for the `subprocess` seam, and it is why this
// feature costs zero lines of DSH source.
//
// WHAT WAS ACTUALLY SHARP-DEPENDENT: five behaviours, all inside this package.
//
//   1. `detectImage` — full decode plus format/dimension/alpha/depth/colour-space
//      facts, and the pixel-count and per-side admission limits.
//   2. `probeImage`  — the same facts from the header alone, used when re-reading
//      a stored object to check it still matches its reference.
//   3. `normalizeImage` — the provider-independent stored form: orient, convert
//      to 8-bit sRGB, fit inside the pixel budget and long-edge cap, encode
//      through a 85/75/60 quality ladder, then verify the result.
//   4. `createRequestImage` — the per-route model-request form: resize by the
//      long edge to the route's pixel budget and re-encode within its byte cap.
//   5. `verifyNormalizedImage` / `verifyRequestImage` — re-probe the bytes just
//      produced and refuse them unless they are single-frame 8-bit sRGB with the
//      dimensions and alpha the caller expects.
//
// All five now call `ISHImageService` over the authenticated loopback channel.
// Everything else — content addressing, staging writes, fsync discipline, the
// immutable object layout, verbatim file storage, the request-image cache — is
// inherited untouched from `LocalAttachmentStore`, so this subclass cannot drift
// from DSH's durability rules.
//
// HEIC: `image/heic` and `image/heif` are ADDED to the accepted source types.
// Nothing downstream ever sees them, because normalisation re-encodes to JPEG or
// PNG; the stored `mediaType` on a reference is always one of DSH's four. They
// are admitted only so the decode can happen here, where it can.
//
// PATH RESOLUTION: this file ships in `plugins/`, beside `payload/`, not inside
// its `node_modules` tree, so a bare import would search `plugins/..` and never
// find the payload's copy. `IOS_SIM_DSH_INSTALL` (which the host sets every
// launch) roots a `createRequire`, honoring each package's `exports` map — the
// same pattern `dsh-subprocess-ish` established. A hardcoded bundle path would
// be wrong on every install.

const { createRequire } = process.getBuiltinModule('node:module');
const { pathToFileURL, fileURLToPath } = process.getBuiltinModule('node:url');
const { dirname, join, resolve: resolvePath } = process.getBuiltinModule('node:path');
const { createHash, randomUUID } = process.getBuiltinModule('node:crypto');
const { mkdir, readFile, rename, rm, writeFile } = process.getBuiltinModule('node:fs/promises');

const HERE = fileURLToPath(new URL('.', import.meta.url));
const PAYLOAD_ROOT = process.env.IOS_SIM_DSH_INSTALL ?? resolvePath(HERE, '..', '..', 'payload');
const requireFromPayload = createRequire(join(PAYLOAD_ROOT, 'package.json'));
const importFromPayload = (specifier) => import(pathToFileURL(requireFromPayload.resolve(specifier)).href);

/** Cordis plugin name used in loader diagnostics. */
export const name = 'attachment-ios';

// WHY NO `#private` METHODS IN THIS FILE.
//
// A cordis `Service` instance is wrapped: `Service`'s constructor returns a
// Proxy (`createCallable`/`joinPrototype`) and `ctx.plugin` may hand callers an
// object derived with `Object.create(this)`. JavaScript's `#name` methods and
// fields check that the RECEIVER is a genuine instance of the declaring class,
// and a proxy or a prototype-derived object is not one. Calling a private method
// through such a receiver throws
//
//     TypeError: Receiver must be an instance of class IosAttachmentStore
//
// inside the caller, where the session controller's catch turns it into the
// catch-all `session/agent-busy` / "prompt rejected" — a message that names
// neither the class nor the cause. Measured: this is exactly what happened on
// the first working HEIC attachment, and the real text only appeared after
// logging the caught error.
//
// So internal helpers here are `_`-prefixed ordinary methods. They are internal
// by convention and documented as such, and unlike `#name` they survive the
// service proxy. Do not convert them back.

const { LocalAttachmentStore, commitPreparedImageFile, canPassThroughNormalization, requestImageVariantId } =
  await importFromPayload('@deepseek-ai/dsh-attachment-local');
const { AttachmentError, AttachmentId, ImageVariantId, requestImageDimensions } =
  await importFromPayload('@deepseek-ai/dsh-attachment');

// `native-image.mjs` is a sibling module. It is imported relatively because it
// is part of this plugin, not a payload package.
const native = await import(new URL('./lib/native-image.mjs', import.meta.url).href);

/** Source types this deployment admits beyond DSH's four. */
const EXTRA_SOURCE_MEDIA_TYPES = Object.freeze(['image/heic', 'image/heif']);

/** The quality ladder DSH uses, restated so the request cache identity is unchanged. */
const IMAGE_ENCODING_QUALITIES = Object.freeze([85, 75, 60]);

/** `sha256:<64 hex>` — the only attachment id shape this store accepts. */
const ID_PATTERN = /^sha256:([a-f0-9]{64})$/;

/** Encodings the platform decoder can PRODUCE. WebP decodes but has no iOS encoder. */
const ENCODABLE_MEDIA_TYPES = Object.freeze(['image/jpeg', 'image/png']);

/** Rejection reason for an aborted attachment operation. */
function abortReason(signal) {
  const reason = signal.reason;
  return reason instanceof Error ? reason : new Error('Attachment request cancelled with a non-Error reason.', { cause: reason });
}

/** Digest of a byte buffer, hex. */
function digest(data) {
  return createHash('sha256').update(data).digest('hex');
}

/**
 * Sanitize a caller display name exactly as DSH's own store does.
 *
 * Both separator styles are stripped by hand: a POSIX host treats `\` as an
 * ordinary character, so `path.basename` would keep a Windows client's full
 * local path and leak it into the reference and the session log.
 * @param {string} [value] - caller-declared display name.
 * @returns {string|undefined} the stored leaf name.
 */
function displayName(value) {
  if (value === undefined) return undefined;
  const clean = value
    .slice(Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\')) + 1)
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .slice(0, 255);
  return clean === '' ? undefined : clean;
}

/** Validate an attachment reference and return its digest. */
function ensureReference(ref) {
  const match = ID_PATTERN.exec(String(ref.attachmentId));
  if (match?.[1] === undefined) throw new AttachmentError('Attachment reference is invalid.', 'INVALID_ATTACHMENT_REF');
  return match[1];
}

/** Absolute immutable-object path for one normalized attachment. */
function normalizedImagePath(root, ref) {
  const sha256 = ensureReference(ref);
  return join(root, 'objects', sha256.slice(0, 2), sha256);
}

/** Forward deep-link paths the layout shares with the base class. */
function requestImageCachePath(root, variantId) {
  const hash = String(variantId).slice(7);
  return join(root, 'request-images', hash.slice(0, 2), hash);
}

/**
 * Map a decoder failure onto DSH's stable attachment codes.
 *
 * The decoder answers `ok: false` with a code from its own small vocabulary;
 * DSH's consumers route on `error.code`, and `read_image` in particular turns
 * `IMAGE_DIMENSION_TOO_LARGE` / `IMAGE_TOO_MANY_PIXELS` / `IMAGE_TOO_LARGE` into
 * actionable sentences. Passing an unmapped code through would degrade those to
 * a generic failure, so the mapping is explicit.
 * @param {object} answer - the decoder's failure answer.
 * @returns {AttachmentError} the mapped error.
 */
function decoderError(answer) {
  const code = answer.code;
  const message = answer.message ?? 'Unsupported or malformed image data.';
  if (code === 'IMAGE_TOO_MANY_PIXELS') return new AttachmentError('Image exceeds the configured decoded-pixel limit.', 'IMAGE_TOO_MANY_PIXELS');
  if (code === 'IMAGE_DIMENSION_TOO_LARGE') return new AttachmentError('Image exceeds the configured per-side pixel limit.', 'IMAGE_DIMENSION_TOO_LARGE');
  if (code === 'ATTACHMENT_WRITE_FAILED') return new AttachmentError(message, 'ATTACHMENT_WRITE_FAILED');
  return new AttachmentError('Unsupported or malformed image data.', 'INVALID_IMAGE');
}

/**
 * Attachment store whose image pipeline runs on ImageIO instead of `sharp`.
 *
 * Only the five sharp-dependent behaviours above are overridden. Every
 * durability rule — staging, fsync, hard-link publication, read-only modes,
 * `EEXIST` deduplication — is inherited, because a re-implementation of those
 * would be the easiest way to quietly corrupt the store.
 */
export class IosAttachmentStore extends LocalAttachmentStore {
  constructor(ctx, config) {
    super(ctx, config);
    // Widen the SOURCE vocabulary. The stored object is always re-encoded to
    // JPEG or PNG, so this does not leak `image/heic` into session logs, request
    // envelopes, or the provider adapters — all of which only ever see the
    // reference produced by normalisation.
    this.imageLimits = Object.freeze({
      ...this.imageLimits,
      mediaTypes: Object.freeze([...this.imageLimits.mediaTypes, ...EXTRA_SOURCE_MEDIA_TYPES]),
    });
    // Said out loud once, at mount, so the boot log itself proves which decoder
    // is in use — the acceptance criterion "no sharp load error" is answered by
    // the absence of a sharp failure AND by this line being present.
    //
    // The storage roots are printed too, and that is not decoration: the base
    // class resolves them from `config.dshHome` falling back to `$DSH_HOME`
    // falling back to `~/.dsh`, and an app whose environment was built wrong
    // would silently write the user's imagery into the desktop harness home.
    // One line in the boot log makes that impossible to miss.
    console.log(`${native.describe()}; objects=${this.root}; request-cache=${this.cacheRoot}`);
  }

  // ------------------------------------------------------------------ decode

  /**
   * Fully decode one image and return its intrinsic facts.
   *
   * `fullDecode` is not decoration: a truncated JPEG or a HEIC whose mdat is
   * cut short still has a perfectly good header. The decoder therefore renders
   * one down-sampled frame and throws it away, which proves the payload decodes
   * without ever materialising the full raster.
   * @param {Uint8Array} data - encoded bytes.
   * @param {object} [limits] - `maxPixels` and `maxDimension` admission limits.
   * @returns {Promise<object>} the detected facts.
   */
  async detectImage(data, limits) {
    let answer;
    try {
      answer = await native.probe(data, {
        maxPixels: limits?.maxPixels ?? 0,
        maxDimension: limits?.maxDimension ?? 0,
      }, { fullDecode: true });
    } catch (error) {
      // A channel failure is an infrastructure fault, not "these bytes are not
      // an image". Naming it that way keeps the model from telling the user
      // their photo is corrupt when the decoder was simply unreachable.
      throw new AttachmentError(`The platform image decoder failed: ${error.message}`, 'ATTACHMENT_READ_FAILED', { cause: error });
    }
    if (answer.ok !== true) throw decoderError(answer);
    return {
      mediaType: answer.mediaType,
      width: answer.width,
      height: answer.height,
      animated: answer.animated === true,
      carriesMetadata: answer.carriesMetadata === true,
      depth: answer.depth,
      space: answer.space,
      hasAlpha: answer.hasAlpha === true,
    };
  }

  /**
   * Read the facts of already-stored bytes from their header alone.
   *
   * Admission already proved these exact bytes decode completely, so the read
   * path only re-derives the reference fields instead of paying a full decode
   * again — the same trade the sharp version makes.
   * @param {Uint8Array} data - complete encoded image bytes.
   * @returns {Promise<object>} the verified facts.
   */
  async probeImage(data) {
    let answer;
    try {
      answer = await native.probe(data, {}, { fullDecode: false });
    } catch (error) {
      throw new AttachmentError(`The platform image decoder failed: ${error.message}`, 'ATTACHMENT_READ_FAILED', { cause: error });
    }
    if (answer.ok !== true) throw decoderError(answer);
    return {
      mediaType: answer.mediaType,
      width: answer.width,
      height: answer.height,
      animated: answer.animated === true,
      carriesMetadata: answer.carriesMetadata === true,
      depth: answer.depth,
      space: answer.space,
      hasAlpha: answer.hasAlpha === true,
    };
  }

  // ------------------------------------------------------------- normalising

  /**
   * Produce the persisted provider-independent normalised version of one source.
   *
   * Pass-through is allowed only for a source that is already exactly what the
   * stored contract wants AND whose format some consumer downstream can read.
   * HEIC never passes through even when it is otherwise clean: the stored object
   * must be a format DSH's own schema admits (PNG/JPEG/WebP/GIF), and HEIC is
   * not one of them.
   * @param {Uint8Array} data - complete admitted source bytes.
   * @param {object} detected - fully decoded source facts.
   * @param {object} policy - resolved normalisation limits.
   * @returns {Promise<object>} verified normalised bytes and metadata.
   */
  async normalizeImage(data, detected, policy) {
    const passthroughAllowed = !EXTRA_SOURCE_MEDIA_TYPES.includes(detected.mediaType);
    if (passthroughAllowed && canPassThroughNormalization(detected, data.byteLength, policy)) {
      // Already clean, already a stored-format raster. The stored `mediaType` is
      // whatever the bytes are; the reference records it verbatim.
      const stored = detected.mediaType === 'image/gif' ? 'image/gif' : detected.mediaType;
      if (ENCODABLE_MEDIA_TYPES.includes(stored) || stored === 'image/webp') {
        return { data, mediaType: stored, width: detected.width, height: detected.height };
      }
    }

    // Dimensions under the total-pixel budget, then the long-edge cap, without
    // changing the aspect ratio — DSH's own rule, applied before the encode so
    // the decoder only ever produces the pixels that will be stored.
    const budgeted = requestImageDimensions(detected.width, detected.height, policy.maxPixels);
    const longEdge = Math.max(budgeted.width, budgeted.height);
    let box = budgeted;
    if (longEdge > policy.maxDimension) {
      const scale = policy.maxDimension / longEdge;
      box = {
        width: Math.max(1, Math.floor(budgeted.width * scale)),
        height: Math.max(1, Math.floor(budgeted.height * scale)),
      };
    }

    const encoded = await this._nativeEncode(data, box, policy.maxBytes, detected.mediaType);
    return this._verifyNormalizedImage(encoded, detected);
  }

  /**
   * Run the platform encoder, refusing transport failures as storage failures.
   * @param {Uint8Array} data - source bytes.
   * @param {object} box - `width`/`height` fit box.
   * @param {number} maxBytes - encoded byte target.
   * @param {string} sourceMediaType - what the source claims, for the error text.
   * @returns {Promise<object>} decoded/encoded bytes and their facts.
   */
  async _nativeEncode(data, box, maxBytes, sourceMediaType) {
    let answer;
    try {
      answer = await native.encode(data, { width: box.width, height: box.height, maxBytes });
    } catch (error) {
      throw new AttachmentError(`The image could not be converted to the normalized 8-bit sRGB form: ${error.message}`, 'ATTACHMENT_WRITE_FAILED', { cause: error });
    }
    if (answer.ok !== true) {
      const mapped = decoderError(answer);
      throw new AttachmentError(
        `The ${sourceMediaType.slice(6).toUpperCase()} could not be converted to the normalized 8-bit sRGB form.`,
        mapped.code === 'INVALID_IMAGE' ? 'ATTACHMENT_WRITE_FAILED' : mapped.code,
        { cause: mapped },
      );
    }
    return {
      data: new Uint8Array(Buffer.from(answer.data, 'base64')),
      mediaType: answer.mediaType,
      width: answer.width,
      height: answer.height,
      depth: answer.depth,
      space: answer.space,
      hasAlpha: answer.hasAlpha === true,
      oversize: answer.oversize === true,
    };
  }

  /**
   * Assert a normalised output really is the form the reference will promise.
   *
   * The decoder reports the facts of the bytes it just produced, computed by
   * re-parsing those bytes on the device. That re-parse IS the verification the
   * sharp version performs with a second decode; the difference is that it
   * happens in the same call instead of a second round trip, so what arrives here
   * is still a measurement of the output rather than a claim about the input.
   * @param {object} image - the encoded result.
   * @param {object} detected - the source facts.
   * @returns {object} the verified result.
   */
  _verifyNormalizedImage(image, detected) {
    const sourceHasAlpha = detected.mediaType === 'image/gif' ? undefined : detected.hasAlpha;
    const alphaCompatible = sourceHasAlpha === undefined
      || image.hasAlpha === sourceHasAlpha
      // PNG and WebP both preserve alpha; an encoder that drops an all-opaque
      // alpha plane is compatible, and so is keeping one.
      || (sourceHasAlpha && !image.hasAlpha && (image.mediaType === 'image/png' || image.mediaType === 'image/webp'));
    if (!ENCODABLE_MEDIA_TYPES.includes(image.mediaType)
      || image.depth !== 'uchar'
      || image.space !== 'srgb'
      || !alphaCompatible) {
      throw new AttachmentError(
        'Image normalization did not produce a single-frame 8-bit sRGB image with matching metadata.',
        'ATTACHMENT_WRITE_FAILED',
      );
    }
    return {
      data: image.data,
      mediaType: image.mediaType,
      width: image.width,
      height: image.height,
    };
  }

  // ----------------------------------------------------------------- prepare

  /**
   * Decode, normalise, and verify one submitted image without touching storage.
   * @param {object} input - encoded bytes, declared media type, optional name.
   * @param {object} limits - source admission policy.
   * @param {object} policy - independent normalisation policy.
   * @returns {Promise<object>} immutable reference facts beside publishable bytes.
   */
  async prepareImageFile(input, limits, policy) {
    if (input.data.byteLength > limits.maxImageBytes) {
      throw new AttachmentError('Image exceeds the configured byte limit.', 'IMAGE_TOO_LARGE');
    }
    if (input.data.byteLength === 0) throw new AttachmentError('Image is empty.', 'INVALID_IMAGE');
    const detected = await this.detectImage(input.data, {
      maxPixels: limits.maxImagePixels,
      maxDimension: limits.maxImageDimension,
    });
    if (detected.mediaType !== input.mediaType) {
      throw new AttachmentError('Declared image type does not match its bytes.', 'IMAGE_TYPE_MISMATCH');
    }
    const normalized = await this.normalizeImage(input.data, detected, policy);
    // The output must itself be a type this deployment accepts, or the reference
    // would point at something `read_image` and the request path then refuse.
    if (!this.imageLimits.mediaTypes.includes(normalized.mediaType)) {
      throw new AttachmentError('Image normalization produced an unacceptable image type.', 'ATTACHMENT_WRITE_FAILED');
    }
    const sha256 = digest(normalized.data);
    const leaf = displayName(input.name);
    const downscaled = detected.width !== normalized.width || detected.height !== normalized.height;
    return {
      data: normalized.data,
      ref: {
        attachmentId: AttachmentId(`sha256:${sha256}`),
        mediaType: normalized.mediaType,
        width: normalized.width,
        height: normalized.height,
        bytes: normalized.data.byteLength,
        ...(leaf !== undefined ? { name: leaf } : {}),
        ...(downscaled ? { originalDimensions: { width: detected.width, height: detected.height } } : {}),
      },
    };
  }

  // ------------------------------------------------------------- public seam

  /** @inheritdoc */
  async validateImage(input) {
    await this.compression.run(() => this.prepareImageFile(input, this.imageLimits, this.normalizationPolicy));
  }

  /** @inheritdoc */
  async saveImages(inputs) {
    this.validateImageBatch(inputs);
    const prepared = await Promise.all(
      inputs.map((input) => this.compression.run(() => this.prepareImageFile(input, this.imageLimits, this.normalizationPolicy))),
    );
    const refs = [];
    for (const image of prepared) refs.push(await commitPreparedImageFile(this.root, image));
    return refs;
  }

  /** @inheritdoc */
  async saveImage(input) {
    const prepared = await this.compression.run(() => this.prepareImageFile(input, this.imageLimits, this.normalizationPolicy));
    return commitPreparedImageFile(this.root, prepared);
  }

  /** @inheritdoc */
  async readImage(ref, signal) {
    signal?.throwIfAborted();
    const sha256 = ensureReference(ref);
    let data;
    try {
      data = new Uint8Array(await readFile(normalizedImagePath(this.root, ref), { signal }));
    } catch (error) {
      signal?.throwIfAborted();
      if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
        throw new AttachmentError('Attachment object is missing.', 'ATTACHMENT_NOT_FOUND');
      }
      throw new AttachmentError('Unable to read image attachment.', 'ATTACHMENT_READ_FAILED', { cause: error });
    }
    signal?.throwIfAborted();
    if (digest(data) !== sha256) throw new AttachmentError('Stored attachment failed integrity verification.', 'ATTACHMENT_CORRUPT');
    const metadata = await this.probeImage(data);
    signal?.throwIfAborted();
    if (metadata.mediaType !== ref.mediaType
      || data.byteLength !== ref.bytes
      || metadata.width !== ref.width
      || metadata.height !== ref.height) {
      throw new AttachmentError('Stored attachment metadata does not match its reference.', 'ATTACHMENT_CORRUPT');
    }
    return { ref, data };
  }

  // ------------------------------------------------------- model-request form

  /** @inheritdoc */
  async readImageRequest(ref, target, signal) {
    return this.requestVersion(ref, target, undefined, signal);
  }

  /**
   * Generate or reuse one request image, with the same de-duplication the sharp
   * version performs: identical concurrent requests share one decode, and the
   * decode is abandoned only when every waiter has gone away.
   * @param {object} ref - durable normalised attachment reference.
   * @param {object} target - route-chosen `width`/`height`/`maxBytes`.
   * @param {object} [stored] - already-read attachment bytes, when the caller has them.
   * @param {AbortSignal} [signal] - caller cancellation.
   * @returns {Promise<object>} request bytes and their deterministic identity.
   */
  requestVersion(ref, target, stored, signal) {
    signal?.throwIfAborted();
    const variantId = requestImageVariantId(ref, target);
    const key = String(variantId);
    let operation = this.requestInflight.get(key);
    if (operation?.controller.signal.aborted) {
      this.requestInflight.delete(key);
      operation = undefined;
    }
    if (operation === undefined) {
      const shared = new SharedImageRequest((sharedSignal) => this.compression.run(async () => {
        const attachment = stored ?? await this.readImage(ref, sharedSignal);
        return this.requestImageFile(attachment, target, sharedSignal);
      }));
      operation = shared;
      this.requestInflight.set(key, shared);
      shared.promise.finally(() => {
        if (this.requestInflight.get(key) === shared) this.requestInflight.delete(key);
      }).catch(() => {});
    }
    return operation.wait(signal);
  }

  /**
   * Build one model-request image from a verified stored attachment.
   *
   * The cache and the transform identity must match `dsh-attachment-local`'s, or
   * a variant written by one implementation would be read as another's: the id
   * comes from the package's own `requestImageVariantId`, and the path from the
   * same `request-images/<aa>/<hash>` layout.
   * @param {object} attachment - `{ ref, data }` from `readImage`.
   * @param {object} target - route-chosen `width`/`height`/`maxBytes`.
   * @param {AbortSignal} [signal] - caller cancellation.
   * @returns {Promise<object>} the request image.
   */
  async requestImageFile(attachment, target, signal) {
    signal?.throwIfAborted();
    const source = await this.probeImage(attachment.data);
    const variantId = requestImageVariantId(attachment.ref, target);
    const path = requestImageCachePath(this.cacheRoot, variantId);
    const cached = await this._readCached(path, target, source.hasAlpha, signal);
    const created = cached ?? await this._createRequestImage(attachment, source, target);
    signal?.throwIfAborted();
    const version = cached ?? {
      ...created,
      hasAlpha: created.hasAlpha ?? source.hasAlpha,
    };
    if (cached === undefined && version.data !== attachment.data) await this._writeCached(path, version.data);
    return {
      variantId,
      attachment: attachment.ref,
      data: version.data,
      mediaType: version.mediaType,
      bytes: version.data.byteLength,
      width: version.width,
      height: version.height,
      depth: 'uchar',
      space: 'srgb',
      hasAlpha: version.hasAlpha,
    };
  }

  /**
   * Produce the request form: keep the stored bytes when they already fit the
   * route's box and byte cap, otherwise resize by the long edge and re-encode.
   * @param {object} attachment - stored attachment bytes and reference.
   * @param {object} source - facts of the stored bytes.
   * @param {object} target - route-chosen `width`/`height`/`maxBytes`.
   * @returns {Promise<object>} request bytes with their measured facts.
   */
  async _createRequestImage(attachment, source, target) {
    if (target.width >= attachment.ref.width
      && target.height >= attachment.ref.height
      && attachment.data.byteLength <= target.maxBytes) {
      // Fits as-is. Identical object identity is how the caller can tell this
      // branch ran; it also means no cache write.
      return {
        data: attachment.data,
        mediaType: attachment.ref.mediaType,
        width: attachment.ref.width,
        height: attachment.ref.height,
        hasAlpha: source.hasAlpha,
      };
    }
    // Resize by the LONG edge alone, exactly as the sharp pipeline does
    // (`resize({ width: target.width })` for a landscape source, `height`
    // otherwise), so the encoder derives the short edge the route predicts.
    const longEdge = attachment.ref.width >= attachment.ref.height ? target.width : target.height;
    const box = { width: attachment.ref.width >= attachment.ref.height ? longEdge : 0, height: attachment.ref.width >= attachment.ref.height ? 0 : longEdge };
    const encoded = await this._nativeEncode(attachment.data, {
      width: box.width === 0 ? Number.MAX_SAFE_INTEGER : box.width,
      height: box.height === 0 ? Number.MAX_SAFE_INTEGER : box.height,
    }, target.maxBytes, attachment.ref.mediaType);
    // The route cap is enforced when the request is assembled; when every ladder
    // step overshot, DSH keeps the smallest and reports the overflow then. Same
    // contract here, so `oversize` is not an error at this layer.
    if (encoded.depth !== 'uchar' || encoded.space !== 'srgb') {
      throw new AttachmentError('Encoded model-request image does not match its verified 8-bit sRGB metadata.', 'ATTACHMENT_WRITE_FAILED');
    }
    return {
      data: encoded.data,
      mediaType: encoded.mediaType,
      width: encoded.width,
      height: encoded.height,
      hasAlpha: encoded.hasAlpha,
    };
  }

  /**
   * Read one cached request image, or nothing when it is absent or stale.
   * @param {string} path - cache path.
   * @param {object} target - route-chosen box and byte cap.
   * @param {boolean} expectedAlpha - alpha fact of the stored source.
   * @param {AbortSignal} [signal] - caller cancellation.
   * @returns {Promise<object|undefined>} the cached image.
   */
  async _readCached(path, target, expectedAlpha, signal) {
    try {
      const data = new Uint8Array(await readFile(path, { signal }));
      const detected = await this.probeImage(data);
      if (detected.depth !== 'uchar'
        || detected.space !== 'srgb'
        || detected.width > target.width
        || detected.height > target.height
        || !this._alphaCompatible(expectedAlpha, detected)) return undefined;
      return {
        data,
        mediaType: detected.mediaType,
        width: detected.width,
        height: detected.height,
        hasAlpha: detected.hasAlpha,
      };
    } catch (error) {
      if (error?.code === 'ENOENT') return undefined;
      signal?.throwIfAborted();
      // Any other cache failure means "no usable cache entry": the transform can
      // be redone, and it must not fail the request.
      return undefined;
    }
  }

  /** Write one request image into the cache, atomically. */
  async _writeCached(path, data) {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, data, { mode: 0o600, flag: 'wx' });
      await rename(temporary, path);
    } finally {
      await rm(temporary, { force: true });
    }
  }

  /**
   * Whether a produced alpha fact is compatible with the source's.
   *
   * An all-opaque source may come back without an alpha plane, and an encoder
   * that preserves alpha is always acceptable; a source WITH alpha coming back
   * as a JPEG has lost transparency, which is not.
   * @param {boolean} sourceHasAlpha - the source's fact.
   * @param {object} output - the produced facts.
   * @returns {boolean} whether the pair is acceptable.
   */
  _alphaCompatible(sourceHasAlpha, output) {
    if (output.hasAlpha === sourceHasAlpha) return true;
    return sourceHasAlpha === true && output.hasAlpha === false && output.mediaType !== 'image/jpeg';
  }
}

/**
 * One shared in-flight image transform.
 *
 * Semantics copied from the sharp version because callers depend on them: the
 * FIRST caller's signal owns cancellation, and the work is abandoned only when
 * the last waiter has gone. A waiter that arrives later and passes no signal
 * simply observes the promise.
 */
class SharedImageRequest {
  /** @type {AbortController} */
  controller = new AbortController();

  /** @type {Promise<object>} */
  promise;

  settled = false;

  waiters = 0;

  /**
   * @param {(signal: AbortSignal) => Promise<object>} start - the transform.
   */
  constructor(start) {
    this.promise = start(this.controller.signal).finally(() => {
      this.settled = true;
    });
  }

  /**
   * Wait for the shared result.
   * @param {AbortSignal} [signal] - this waiter's cancellation.
   * @returns {Promise<object>} the result.
   */
  wait(signal) {
    signal?.throwIfAborted();
    this.waiters += 1;
    if (signal === undefined) {
      return this.promise.finally(() => {
        this.release(false);
      });
    }
    let released = false;
    const release = (cancelled) => {
      if (released) return;
      released = true;
      this.release(cancelled, signal);
    };
    return new Promise((resolve, reject) => {
      const abort = () => {
        release(true);
        reject(abortReason(signal));
      };
      signal.addEventListener('abort', abort, { once: true });
      this.promise.then((value) => {
        signal.removeEventListener('abort', abort);
        release(false);
        resolve(value);
      }, (error) => {
        signal.removeEventListener('abort', abort);
        release(false);
        reject(error instanceof Error ? error : new Error('image transform rejected with a non-Error value', { cause: error }));
      });
    });
  }

  /**
   * Drop one waiter, aborting the work when it was the last one.
   * @param {boolean} cancelled - whether this waiter left by aborting.
   * @param {AbortSignal} [signal] - the waiter's signal.
   */
  release(cancelled, signal) {
    this.waiters -= 1;
    if (cancelled && this.waiters === 0 && !this.settled && signal !== undefined) {
      this.controller.abort(abortReason(signal));
    }
  }
}

/**
 * Load the store.
 *
 * Refuses to mount when the platform decoder is not reachable, because the
 * alternative is worse: a store that admits images and then fails every one of
 * them, long after the user pressed send, looks like a broken app rather than a
 * missing decoder. A loud boot error names the real cause.
 * @param {object} ctx - cordis context.
 * @param {object} config - the row's config, passed through to the store.
 */
export function apply(ctx, config) {
  // A store with no pinned root would resolve the user's desktop harness home on
  // a machine where `$DSH_HOME` was lost, so refuse to mount without one. This is
  // a hard requirement, not a warning: the failure mode is writing the user's
  // photographs into their own `~/.dsh`, and an app that will not start is a far
  // better outcome than one that does that silently.
  if (typeof config?.dshHome !== 'string' || config.dshHome === '') {
    throw new Error(
      'attachment-ios: config.dshHome is required. The store must be pinned to the app container; '
      + 'without it the base class falls back to $DSH_HOME and then ~/.dsh, which on a phone means '
      + 'a path that does not exist and on a shared machine means the user\'s own desktop harness home.',
    );
  }
  if (!native.isConfigured()) {
    throw new Error(
      'attachment-ios: the platform image service is not configured (no DSH_GUEST_CHANNEL_URL/TOKEN). '
      + 'This store decodes images through the app\'s channel; without it, every image would be refused.',
    );
  }
  ctx.plugin(IosAttachmentStore, config);
}

export default { name, apply, inject: [] };
