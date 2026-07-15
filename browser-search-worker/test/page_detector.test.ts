import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { detectPageState } from "../src/services/page_detector.js";

function fixture(name: string): string {
  return readFileSync(join(import.meta.dirname, "fixtures", name), "utf8");
}

describe("detectPageState", () => {
  it("detects CAPTCHA pages", () => {
    expect(detectPageState(fixture("google_captcha.html"), "https://www.google.com/sorry/index")).toEqual({
      captcha: true,
      consentPage: false,
      rateLimited: false,
    });
  });

  it("detects consent pages", () => {
    expect(detectPageState(fixture("google_consent.html"), "https://consent.google.com/")).toEqual({
      captcha: false,
      consentPage: true,
      rateLimited: false,
    });
  });

  it("detects automated query restriction pages", () => {
    expect(detectPageState(fixture("google_rate_limited.html"), "https://www.google.com/search?q=test")).toEqual({
      captcha: false,
      consentPage: false,
      rateLimited: true,
    });
  });

  it("does not flag normal result pages", () => {
    expect(detectPageState(fixture("google_results.html"), "https://www.google.com/search?q=test")).toEqual({
      captcha: false,
      consentPage: false,
      rateLimited: false,
    });
  });
});
