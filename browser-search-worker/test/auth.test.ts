import { describe, expect, it } from "vitest";
import Fastify from "fastify";
import { authenticateRequest } from "../src/auth.js";
import { loadConfig } from "../src/config.js";

describe("Bearer authentication", () => {
  it("accepts a valid bearer token", async () => {
    const server = Fastify();
    const config = loadConfig({
      NODE_ENV: "test",
      BROWSER_WORKER_TOKEN: "secret",
      BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
    });
    server.get("/protected", { preHandler: authenticateRequest(config) }, async () => ({ status: "ok" }));

    const response = await server.inject({
      method: "GET",
      url: "/protected",
      headers: { authorization: "Bearer secret" },
    });

    expect(response.statusCode).toBe(200);
  });

  it("rejects an invalid bearer token", async () => {
    const server = Fastify();
    const config = loadConfig({
      NODE_ENV: "test",
      BROWSER_WORKER_TOKEN: "secret",
      BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
    });
    server.get("/protected", { preHandler: authenticateRequest(config) }, async () => ({ status: "ok" }));

    const response = await server.inject({
      method: "GET",
      url: "/protected",
      headers: { authorization: "Bearer wrong" },
    });

    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("unauthorized");
  });

  it("requires token configuration in production", () => {
    expect(() =>
      loadConfig({
        NODE_ENV: "production",
        BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
      }),
    ).toThrow("BROWSER_WORKER_TOKEN is required in production");
  });
});
