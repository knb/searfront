import puppeteer from "puppeteer-core";
import type { Config } from "./config.js";

export async function checkBrowserless(config: Config): Promise<boolean> {
  let browser;

  try {
    browser = await puppeteer.connect({
      browserWSEndpoint: browserlessEndpoint(config),
      protocolTimeout: config.browserlessConnectTimeoutMs,
    });
    await browser.version();
    return true;
  } catch {
    return false;
  } finally {
    if (browser) {
      await browser.disconnect();
    }
  }
}

export function browserlessEndpoint(config: Config): string {
  const url = new URL(config.browserlessWsEndpoint);
  if (config.browserlessToken) {
    url.searchParams.set("token", config.browserlessToken);
  }
  return url.toString();
}
