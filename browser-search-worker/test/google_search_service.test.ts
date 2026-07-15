import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { SearchError } from "../src/errors/search_error.js";
import { searchGoogle } from "../src/services/google_search.js";

const fixturesDir = join(import.meta.dirname, "fixtures");

const config = loadConfig({
  NODE_ENV: "test",
  BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000",
  GOOGLE_MIN_INTERVAL_MS: "0",
  GOOGLE_INTERVAL_JITTER_MS: "0",
});

describe("searchGoogle", () => {
  it("returns parsed Google results", async () => {
    const browser = fakeBrowser(readFixture("google_results.html"), "https://www.google.com/search?q=example");
    const response = await searchGoogle(
      { query: "example", language: "ja", country: "JP", limit: 10 },
      config,
      {
        connectBrowser: async () => browser,
        now: fakeClock(100, 140),
      },
    );

    expect(response.status).toBe("ok");
    expect(response.elapsed_ms).toBe(40);
    expect(response.results).toHaveLength(2);
    expect(response.results[0]?.url).toBe("https://github.com/ggml-org/llama.cpp?utm_source=google");
  });

  it("raises a CAPTCHA error when Google blocks the page", async () => {
    const browser = fakeBrowser(readFixture("google_captcha.html"), "https://www.google.com/sorry/index");

    await expect(
      searchGoogle({ query: "example", language: "ja", country: "JP", limit: 10 }, config, {
        connectBrowser: async () => browser,
      }),
    ).rejects.toMatchObject({
      code: "google_captcha",
      statusCode: 429,
      suspendSeconds: 86_400,
    } satisfies Partial<SearchError>);
  });

  it("raises a parse error when no result container exists", async () => {
    const browser = fakeBrowser("<html><body>unexpected page</body></html>", "https://www.google.com/search?q=example");

    await expect(
      searchGoogle({ query: "example", language: "ja", country: "JP", limit: 10 }, config, {
        connectBrowser: async () => browser,
      }),
    ).rejects.toMatchObject({
      code: "google_parse_error",
      statusCode: 502,
    } satisfies Partial<SearchError>);
  });
});

function readFixture(name: string): string {
  return readFileSync(join(fixturesDir, name), "utf8");
}

function fakeClock(...values: number[]): () => number {
  let index = 0;
  return () => values[Math.min(index++, values.length - 1)] ?? 0;
}

function fakeBrowser(html: string, url: string) {
  const page = {
    setViewport: async () => undefined,
    setRequestInterception: async () => undefined,
    on: () => page,
    goto: async () => undefined,
    waitForSelector: async () => undefined,
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
