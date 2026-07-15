import { z } from "zod";

const configSchema = z.object({
  nodeEnv: z.string().default("development"),
  port: z.coerce.number().int().positive().default(3000),
  browserWorkerToken: z.string().optional(),
  browserlessWsEndpoint: z.string().url().default("ws://browserless:3000"),
  browserlessToken: z.string().optional(),
  browserlessConnectTimeoutMs: z.coerce.number().int().positive().default(10_000),
  googleMinIntervalMs: z.coerce.number().int().nonnegative().default(15_000),
  googleIntervalJitterMs: z.coerce.number().int().nonnegative().default(5_000),
  googleNavigationTimeoutMs: z.coerce.number().int().positive().default(30_000),
  googleResultTimeoutMs: z.coerce.number().int().positive().default(10_000),
  debugArtifactsEnabled: z.coerce.boolean().default(false),
  debugArtifactsDir: z.string().default("./debug"),
  debugArtifactTtlHours: z.coerce.number().int().positive().default(24),
});

export type Config = z.infer<typeof configSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const config = configSchema.parse({
    nodeEnv: env.NODE_ENV,
    port: env.PORT,
    browserWorkerToken: env.BROWSER_WORKER_TOKEN,
    browserlessWsEndpoint: env.BROWSERLESS_WS_ENDPOINT,
    browserlessToken: env.BROWSERLESS_TOKEN,
    browserlessConnectTimeoutMs: env.BROWSERLESS_CONNECT_TIMEOUT_MS,
    googleMinIntervalMs: env.GOOGLE_MIN_INTERVAL_MS,
    googleIntervalJitterMs: env.GOOGLE_INTERVAL_JITTER_MS,
    googleNavigationTimeoutMs: env.GOOGLE_NAVIGATION_TIMEOUT_MS,
    googleResultTimeoutMs: env.GOOGLE_RESULT_TIMEOUT_MS,
    debugArtifactsEnabled: env.DEBUG_ARTIFACTS_ENABLED,
    debugArtifactsDir: env.DEBUG_ARTIFACTS_DIR,
    debugArtifactTtlHours: env.DEBUG_ARTIFACT_TTL_HOURS,
  });

  if (config.nodeEnv === "production" && !config.browserWorkerToken) {
    throw new Error("BROWSER_WORKER_TOKEN is required in production");
  }

  return config;
}
