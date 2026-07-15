import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { SearchError } from "../src/errors/search_error.js";
import { searchGoogle } from "../src/services/google_search.js";

const fixturesDir = join(import.meta.dirname, "fixtures");

const config = loadConfig({
  NODE_ENV: "test",
  BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
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
    expect(browser.actions).toEqual([
      ["goto", "https://www.google.com/?hl=ja&gl=JP"],
      ["waitForSelector", "textarea[name='q'], input[name='q']"],
      ["type", "textarea[name='q'], input[name='q']", "example"],
      ["press", "Enter"],
      ["waitForNavigation"],
      ["waitForSelector", "#search, form[action*='/sorry'], iframe[src*='recaptcha'], body"],
    ]);
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

  it("writes debug artifacts when enabled", async () => {
    const debugDir = mkdtempSync(join(tmpdir(), "searfront-debug-"));
    const browser = fakeBrowser(readFixture("google_captcha.html"), "https://www.google.com/sorry/index");
    const debugConfig = loadConfig({
      NODE_ENV: "test",
      BROWSERLESS_WS_ENDPOINT: "ws://browserless:3000/chromium",
      GOOGLE_MIN_INTERVAL_MS: "0",
      GOOGLE_INTERVAL_JITTER_MS: "0",
      DEBUG_ARTIFACTS_ENABLED: "true",
      DEBUG_ARTIFACTS_DIR: debugDir,
    });

    try {
      await expect(
        searchGoogle({ query: "secret query", language: "ja", country: "JP", limit: 10, requestId: "request-1" }, debugConfig, {
          connectBrowser: async () => browser,
        }),
      ).rejects.toMatchObject({ code: "google_captcha" });

      const entries = readdirSync(debugDir);
      expect(entries).toHaveLength(1);
      const dir = join(debugDir, entries[0] ?? "");
      const metadata = JSON.parse(readFileSync(join(dir, "metadata.json"), "utf8"));
      expect(metadata).toMatchObject({
        request_id: "request-1",
        status: "captcha",
        url: "https://www.google.com/sorry/index",
      });
      expect(metadata.query_digest).toMatch(/^sha256:/);
      expect(JSON.stringify(metadata)).not.toContain("secret query");
      expect(readFileSync(join(dir, "page.html"), "utf8")).toContain("g-recaptcha");
      expect(readFileSync(join(dir, "screenshot.png"))).toEqual(Buffer.from("png"));
    } finally {
      rmSync(debugDir, { recursive: true, force: true });
    }
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
  const actions: unknown[][] = [];
  const page = {
    setViewport: async () => undefined,
    setRequestInterception: async () => undefined,
    on: () => page,
    goto: async (targetUrl: string) => {
      actions.push(["goto", targetUrl]);
    },
    waitForSelector: async (selector: string) => {
      actions.push(["waitForSelector", selector]);
    },
    type: async (selector: string, value: string) => {
      actions.push(["type", selector, value]);
    },
    keyboard: {
      press: async (key: string) => {
        actions.push(["press", key]);
      },
    },
    waitForNavigation: async () => {
      actions.push(["waitForNavigation"]);
    },
    content: async () => html,
    url: () => url,
    screenshot: async () => Buffer.from("png"),
  };
  const context = {
    newPage: async () => page,
    close: async () => undefined,
  };
  return {
    actions,
    createBrowserContext: async () => context,
    disconnect: async () => undefined,
  };
}
