import type { CloudEvent } from "firebase-functions/v2";
import type { StorageObjectData } from "firebase-functions/v2/storage";
import sharp from "sharp";
import { getStorage } from "firebase-admin/storage";
import { logEvent } from "../logger";

/**
 * Server-side counterpart to the client-only resize pipeline described in
 * docs/decisions/resolved-v1.md's "Cloud Sync" section. Fires on every
 * finalized object in the default bucket (Cloud Functions v2 Storage
 * triggers have no path-glob filtering), so this handler filters to
 * wardrobe originals itself and no-ops on everything else, including its
 * own writes — see the two guards at the top of handleWardrobeImageFinalized.
 *
 * Does two things per original upload:
 *  1. Generates a small thumbnail variant (see THUMBNAIL_MAX_DIMENSION's
 *     justification below) at users/{uid}/wardrobeImages/thumbnails/{fileName},
 *     read-only to the owning client (backend/storage.rules), so grid/list
 *     views never need to download the full-resolution asset.
 *  2. Normalizes any original whose longest edge exceeds the client's own
 *     upload-time target (1024px, ImageStorage.swift's
 *     downscaledPNGForUpload/downscaledJPEGForUpload) — a safety net for a
 *     buggy/outdated client build that skipped or failed its own downscale.
 */

const WARDROBE_IMAGE_PATH = /^users\/([^/]+)\/wardrobeImages\/([^/]+)$/;

// Largest grid call site (ManualPairingView.swift) renders at 100x100pt;
// at 3x device scale that's 300px physical pixels. 384px gives ~28%
// headroom for future grid growth/rounding slop while staying at roughly
// (384/1024)^2 ~= 14% of the full asset's pixel area.
const THUMBNAIL_MAX_DIMENSION = 384;

// Matches ImageStorage's client-side upload-time default so the safety net
// converges to the same canonical size a well-behaved client already
// produces, not a second size the app has to reconcile against.
const NORMALIZE_TARGET_DIMENSION = 1024;
// Only re-encode when meaningfully over target, to avoid churn on images
// already close to 1024px from normal encoding rounding.
const NORMALIZE_TRIGGER_DIMENSION = NORMALIZE_TARGET_DIMENSION * 1.1;

export async function handleWardrobeImageFinalized(event: CloudEvent<StorageObjectData>): Promise<void> {
  const filePath = event.data.name ?? "";
  const match = WARDROBE_IMAGE_PATH.exec(filePath);
  // Not a wardrobe original (portrait, our own thumbnails/ sub-path,
  // anything else) — the regex alone already excludes thumbnails/ (extra
  // path segment), the includes() check just documents that for readers.
  if (!match || filePath.includes("/thumbnails/")) return;
  // Our own normalize-in-place overwrite re-finalizing — fast no-op, this
  // is what breaks the self-trigger loop for that write.
  if (event.data.metadata?.vcNormalized === "1") return;

  const [, uid, fileName] = match;
  const start = Date.now();
  logEvent("info", "thumbnailGen.start", {
    objectName: filePath,
    uid,
    generation: event.data.generation,
    sizeBytes: Number(event.data.size ?? 0),
  });

  try {
    const bucket = getStorage().bucket(event.data.bucket);
    const file = bucket.file(filePath);
    const [buffer] = await file.download();
    const contentType = event.data.contentType ?? "image/png";
    const isPng = contentType === "image/png";

    const meta = await sharp(buffer).metadata();
    const longestEdge = Math.max(meta.width ?? 0, meta.height ?? 0);

    // 1) Thumbnail — always regenerated fresh from the original bytes.
    let thumbPipeline = sharp(buffer).rotate().resize({
      width: THUMBNAIL_MAX_DIMENSION,
      height: THUMBNAIL_MAX_DIMENSION,
      fit: "inside",
      withoutEnlargement: true,
    });
    thumbPipeline = isPng ? thumbPipeline.png() : thumbPipeline.jpeg({ quality: 82 });
    const thumbBuffer = await thumbPipeline.toBuffer();
    await bucket.file(`users/${uid}/wardrobeImages/thumbnails/${fileName}`).save(thumbBuffer, {
      metadata: { contentType },
    });

    // 2) Normalize-in-place — only if the client skipped/failed its own
    // downscale. Tagged with vcNormalized so the re-triggered finalize
    // event on this same overwrite is a no-op (guard above).
    let normalized = false;
    if (longestEdge > NORMALIZE_TRIGGER_DIMENSION) {
      let normPipeline = sharp(buffer).rotate().resize({
        width: NORMALIZE_TARGET_DIMENSION,
        height: NORMALIZE_TARGET_DIMENSION,
        fit: "inside",
        withoutEnlargement: true,
      });
      normPipeline = isPng ? normPipeline.png() : normPipeline.jpeg({ quality: 85 });
      const normalizedBuffer = await normPipeline.toBuffer();
      await file.save(normalizedBuffer, {
        metadata: { contentType, metadata: { vcNormalized: "1" } },
      });
      normalized = true;
    }

    logEvent("info", "thumbnailGen.finish", {
      objectName: filePath,
      uid,
      durationMs: Date.now() - start,
      thumbBytes: thumbBuffer.length,
      normalized,
      originalWidth: meta.width,
      originalHeight: meta.height,
    });
  } catch (error) {
    // Fail-open, no throw — an uncaught throw in an event-triggered
    // function causes Cloud Functions to keep re-delivering the same
    // finalize event (retry storm). Log and return; the original upload
    // stays servable as-is, just without a thumbnail this cycle.
    logEvent("warn", "thumbnailGen.failed", {
      objectName: filePath,
      uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
  }
}
