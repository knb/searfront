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

export async function writeDebugMetadata(baseDir: string, metadata: ArtifactMetadata): Promise<string> {
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
