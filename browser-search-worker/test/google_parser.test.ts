import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { normalizeResultUrl, parseGoogleResults } from "../src/services/google_parser.js";

function fixture(name: string): string {
  return readFileSync(join(import.meta.dirname, "fixtures", name), "utf8");
}

describe("parseGoogleResults", () => {
  it("extracts organic results and removes duplicates and Google internal URLs", () => {
    const results = parseGoogleResults(fixture("google_results.html"));

    expect(results).toEqual([
      {
        position: 1,
        title: "llama.cpp",
        url: "https://github.com/ggml-org/llama.cpp?utm_source=google",
        content: "LLM inference in C/C++ with Vulkan support.",
      },
      {
        position: 2,
        title: "Vulkan backend notes",
        url: "https://example.com/vulkan",
        content: "Example snippet without the common snippet class.",
      },
    ]);
  });

  it("returns an empty list for empty or invalid result pages", () => {
    expect(parseGoogleResults(fixture("google_empty.html"))).toEqual([]);
    expect(parseGoogleResults(fixture("google_invalid.html"))).toEqual([]);
  });
});

describe("normalizeResultUrl", () => {
  it("unwraps Google redirect URLs", () => {
    expect(normalizeResultUrl("https://www.google.com/url?q=https%3A%2F%2Fexample.org%2Fdocs%2F&sa=U")).toBe(
      "https://example.org/docs",
    );
  });

  it("rejects unsafe and internal URLs", () => {
    expect(normalizeResultUrl("javascript:alert(1)")).toBeNull();
    expect(normalizeResultUrl("https://www.google.com/search?q=test")).toBeNull();
  });
});
