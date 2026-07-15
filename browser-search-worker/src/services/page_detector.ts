export type PageDetection = {
  captcha: boolean;
  consentPage: boolean;
  rateLimited: boolean;
};

export function detectPageState(html: string, url: string): PageDetection {
  const normalizedHtml = html.toLowerCase();
  const normalizedText = stripTags(html).toLowerCase();
  const normalizedUrl = url.toLowerCase();

  return {
    captcha: detectCaptcha(normalizedHtml, normalizedText, normalizedUrl),
    consentPage: detectConsent(normalizedHtml, normalizedText, normalizedUrl),
    rateLimited: detectRateLimit(normalizedText),
  };
}

function detectCaptcha(html: string, text: string, url: string): boolean {
  return (
    url.includes("/sorry/") ||
    html.includes('action="/sorry') ||
    html.includes("action='/sorry") ||
    html.includes('src="https://www.google.com/recaptcha') ||
    html.includes("g-recaptcha") ||
    text.includes("captcha")
  );
}

function detectConsent(html: string, text: string, url: string): boolean {
  return (
    url.includes("consent.google.com") ||
    html.includes("consent.google.com") ||
    html.includes('action="https://consent.google.com') ||
    text.includes("同意する") ||
    text.includes("すべて同意") ||
    text.includes("i agree")
  );
}

function detectRateLimit(text: string): boolean {
  return (
    text.includes("our systems have detected unusual traffic") ||
    text.includes("automated queries") ||
    text.includes("unusual traffic from your computer network") ||
    text.includes("通常と異なるトラフィック") ||
    text.includes("自動クエリ")
  );
}

function stripTags(html: string): string {
  return html.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ");
}
