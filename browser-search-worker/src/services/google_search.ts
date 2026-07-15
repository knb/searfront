import type { Browser, BrowserContext, HTTPRequest, Page } from "puppeteer-core";
import { randomUUID } from "node:crypto";
import { connectBrowserless } from "../browser.js";
import type { Config } from "../config.js";
import { writeDebugArtifact } from "../debug/artifact_writer.js";
import {
  browserlessUnavailableError,
  googleCaptchaError,
  googleConsentRequiredError,
  googleParseError,
  googleRateLimitedError,
  googleTimeoutError,
  SearchError,
} from "../errors/search_error.js";
import type { SearchResponse } from "../schemas/search_response.js";
import { parseGoogleResults } from "./google_parser.js";
import { detectPageState } from "./page_detector.js";
import { RateLimiter } from "./rate_limiter.js";

export type GoogleSearchInput = {
  query: string;
  language: string;
  country: string;
  limit: number;
  requestId?: string;
};

export type GoogleSearchDependencies = {
  connectBrowser?: (config: Config) => Promise<Browser>;
  rateLimiter?: RateLimiter;
  now?: () => number;
};

const defaultRateLimiters = new WeakMap<Config, RateLimiter>();

export async function searchGoogle(
  input: GoogleSearchInput,
  config: Config,
  dependencies: GoogleSearchDependencies = {},
): Promise<SearchResponse> {
  const startedAt = dependencies.now?.() ?? Date.now();
  const rateLimiter = dependencies.rateLimiter ?? defaultRateLimiter(config);

  await rateLimiter.wait();

  const browser = await connectBrowser(config, dependencies);
  let context: BrowserContext | undefined;
  let page: Page | undefined;
  let artifactWritten = false;

  try {
    context = await browser.createBrowserContext();
    page = await context.newPage();
    await configurePage(page);

    try {
      await submitSearchFromHomepage(page, input, config);
      await waitForSearchPage(page, config.googleResultTimeoutMs);
    } catch (error) {
      artifactWritten = await writeArtifactIfEnabled(config, page, input, "timeout");
      throw mapTimeoutError(error);
    }

    const html = await page.content();
    const detected = detectPageState(html, page.url());

    if (detected.captcha) {
      artifactWritten = await writeArtifactIfEnabled(config, page, input, "captcha");
      throw googleCaptchaError();
    }
    if (detected.rateLimited) {
      artifactWritten = await writeArtifactIfEnabled(config, page, input, "rate_limited");
      throw googleRateLimitedError();
    }
    if (detected.consentPage) {
      artifactWritten = await writeArtifactIfEnabled(config, page, input, "consent_required");
      throw googleConsentRequiredError();
    }

    const results = parseGoogleResults(html).slice(0, input.limit);
    if (html.includes("id=\"search\"") && results.length === 0) {
      await writeArtifactIfEnabled(config, page, input, "empty");
      return buildResponse(input, "empty", results, detected, elapsedMs(startedAt, dependencies));
    }
    if (results.length === 0) {
      artifactWritten = await writeArtifactIfEnabled(config, page, input, "parse_error");
      throw googleParseError();
    }

    return buildResponse(input, "ok", results, detected, elapsedMs(startedAt, dependencies));
  } catch (error) {
    if (!artifactWritten && !(error instanceof SearchError) && page) {
      await writeArtifactIfEnabled(config, page, input, "unexpected_error");
    }
    throw error;
  } finally {
    await context?.close();
    await browser.disconnect();
  }
}

function defaultRateLimiter(config: Config): RateLimiter {
  const existing = defaultRateLimiters.get(config);
  if (existing) {
    return existing;
  }

  const rateLimiter = new RateLimiter(config.googleMinIntervalMs, config.googleIntervalJitterMs);
  defaultRateLimiters.set(config, rateLimiter);
  return rateLimiter;
}

async function connectBrowser(config: Config, dependencies: GoogleSearchDependencies): Promise<Browser> {
  try {
    return await (dependencies.connectBrowser ?? connectBrowserless)(config);
  } catch (error) {
    if (error instanceof SearchError) {
      throw error;
    }
    throw browserlessUnavailableError();
  }
}

async function configurePage(page: Page): Promise<void> {
  await page.setViewport({
    width: 1280,
    height: 900,
    deviceScaleFactor: 1,
  });
  await page.setRequestInterception(true);
  page.on("request", (request: HTTPRequest) => {
    if (request.resourceType() === "image") {
      void request.abort();
      return;
    }
    void request.continue();
  });
}

async function submitSearchFromHomepage(page: Page, input: GoogleSearchInput, config: Config): Promise<void> {
  const url = buildGoogleHomeUrl(input);
  await page.goto(url, {
    waitUntil: "domcontentloaded",
    timeout: config.googleNavigationTimeoutMs,
  });
  await page.waitForSelector("textarea[name='q'], input[name='q']", {
    timeout: config.googleResultTimeoutMs,
  });
  await page.type("textarea[name='q'], input[name='q']", input.query);
  await page.keyboard.press("Enter");
  await page.waitForNavigation({
    waitUntil: "domcontentloaded",
    timeout: config.googleNavigationTimeoutMs,
  });
}

function buildGoogleHomeUrl(input: GoogleSearchInput): string {
  const url = new URL("https://www.google.com/");
  url.searchParams.set("hl", input.language);
  url.searchParams.set("gl", input.country);
  return url.toString();
}

async function waitForSearchPage(page: Page, timeout: number): Promise<void> {
  await page.waitForSelector("#search, form[action*='/sorry'], iframe[src*='recaptcha'], body", {
    timeout,
  });
}

function mapTimeoutError(error: unknown): SearchError {
  if (error instanceof SearchError) {
    return error;
  }

  return googleTimeoutError();
}

function buildResponse(
  input: GoogleSearchInput,
  status: "ok" | "empty",
  results: SearchResponse["results"],
  detected: ReturnType<typeof detectPageState>,
  elapsed_ms: number,
): SearchResponse {
  return {
    engine: "google-browser",
    query: input.query,
    status,
    results,
    detected: {
      captcha: detected.captcha,
      consent_page: detected.consentPage,
      rate_limited: detected.rateLimited,
    },
    elapsed_ms,
  };
}

function elapsedMs(startedAt: number, dependencies: GoogleSearchDependencies): number {
  return Math.max((dependencies.now?.() ?? Date.now()) - startedAt, 0);
}

async function writeArtifactIfEnabled(
  config: Config,
  page: Page,
  input: GoogleSearchInput,
  status: string,
): Promise<boolean> {
  if (!config.debugArtifactsEnabled) {
    return false;
  }

  const html = await page.content();
  const screenshot = await page.screenshot({ type: "png" });
  await writeDebugArtifact(config.debugArtifactsDir, {
    metadata: {
      requestId: input.requestId ?? randomUUID(),
      query: input.query,
      url: page.url(),
      status,
      createdAt: new Date().toISOString(),
    },
    html,
    screenshot,
  });
  return true;
}
