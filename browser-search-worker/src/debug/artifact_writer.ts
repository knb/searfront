import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";

export type ArtifactMetadata = {
  requestId: string;
  query: string;
  url: string;
  status: string;
  createdAt: string;
};

export type DebugArtifact = {
  metadata: ArtifactMetadata;
  html: string;
  screenshot?: Uint8Array | Buffer;
};

export async function writeDebugArtifact(baseDir: string, artifact: DebugArtifact): Promise<string> {
  const dir = await writeDebugMetadata(baseDir, artifact.metadata);
  await writeFile(join(dir, "page.html"), artifact.html);
  if (artifact.screenshot) {
    await writeFile(join(dir, "screenshot.png"), artifact.screenshot);
  }
  return dir;
}

async function writeDebugMetadata(baseDir: string, metadata: ArtifactMetadata): Promise<string> {
  const digest = createHash("sha256").update(metadata.query).digest("hex");
  const dir = join(baseDir, `${metadata.createdAt.replace(/[:.]/g, "")}-${metadata.requestId}`);
  await mkdir(dir, { recursive: true });
  await writeFile(
    join(dir, "metadata.json"),
    JSON.stringify(
      {
        request_id: metadata.requestId,
        query_digest: `sha256:${digest}`,
        url: metadata.url,
        status: metadata.status,
        created_at: metadata.createdAt,
      },
      null,
      2,
    ),
  );
  return dir;
}
