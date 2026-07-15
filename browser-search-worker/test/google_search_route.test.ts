import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import { googleRateLimitedError } from "../src/errors/search_error.js";

const config = loadConfig({
  NODE_ENV: "test",
  BROWSER_WORKER_TOKEN: "secret",
  BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
  GOOGLE_MIN_INTERVAL_MS: "0",
  GOOGLE_INTERVAL_JITTER_MS: "0",
});

describe("POST /v1/search/google", () => {
  it("validates request bodies", async () => {
    const server = buildServer({ config });

    const response = await server.inject({
      method: "POST",
      url: "/v1/search/google",
      headers: { authorization: "Bearer secret" },
      payload: { query: "", unexpected: true },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("invalid_request");
  });

  it("returns search results", async () => {
    const browser = fakeBrowser(
      `
        <div id="search">
          <div class="g">
            <a href="https://example.com/"><h3>Example</h3></a>
            <span>Snippet</span>
          </div>
        </div>
      `,
      "https://www.google.com/search?q=example",
    );
    const server = buildServer({
      config,
      googleSearchDependencies: {
        connectBrowser: async () => browser,
      },
    });

    const response = await server.inject({
      method: "POST",
      url: "/v1/search/google",
      headers: { authorization: "Bearer secret" },
      payload: { query: "example" },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      engine: "google-browser",
      query: "example",
      status: "ok",
      results: [{ position: 1, title: "Example", url: "https://example.com/", content: "Snippet" }],
    });
  });

  it("maps search errors to machine-readable responses", async () => {
    const server = buildServer({
      config,
      googleSearchDependencies: {
        connectBrowser: async () => {
          throw googleRateLimitedError();
        },
      },
    });

    const response = await server.inject({
      method: "POST",
      url: "/v1/search/google",
      headers: { authorization: "Bearer secret" },
      payload: { query: "example" },
    });

    expect(response.statusCode).toBe(429);
    expect(response.json()).toMatchObject({
      status: "blocked",
      error: {
        code: "google_rate_limited",
        retryable: false,
        suspend_seconds: 7200,
      },
      detected: {
        rate_limited: true,
      },
    });
  });
});

function fakeBrowser(html: string, url: string) {
  const page = {
    setViewport: async () => undefined,
    setRequestInterception: async () => undefined,
    on: () => page,
    goto: async () => undefined,
    waitForSelector: async () => undefined,
    type: async () => undefined,
    keyboard: {
      press: async () => undefined,
    },
    waitForNavigation: async () => undefined,
    content: async () => html,
    url: () => url,
  };
  const context = {
    newPage: async () => page,
    close: async () => undefined,
  };
  return {
    createBrowserContext: async () => context,
    disconnect: async () => undefined,
  };
}
