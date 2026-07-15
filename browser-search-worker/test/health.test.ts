import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";

const config = loadConfig({
  NODE_ENV: "test",
  PORT: "3000",
  BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000",
});

describe("GET /health", () => {
  it("returns ok when Browserless is reachable", async () => {
    const server = buildServer({ config, browserlessCheck: async () => true });

    const response = await server.inject({ method: "GET", url: "/health" });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "ok", browserless: "reachable" });
  });

  it("returns degraded when Browserless is unreachable", async () => {
    const server = buildServer({ config, browserlessCheck: async () => false });

    const response = await server.inject({ method: "GET", url: "/health" });

    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ status: "degraded", browserless: "unreachable" });
  });
});
