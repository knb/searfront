export type ParsedGoogleResult = {
  position: number;
  title: string;
  url: string;
  content: string;
};

type Candidate = {
  title: string;
  url: string;
  content: string;
};

const blockPatterns = [
  /<div\b[^>]*class=["'][^"']*\bg\b[^"']*["'][^>]*>[\s\S]*?<\/div>\s*<\/div>/gi,
  /<div\b[^>]*class=["'][^"']*\bMjjYud\b[^"']*["'][^>]*>[\s\S]*?<\/div>\s*<\/div>/gi,
  /<div\b[^>]*data-sokoban-container\b[^>]*>[\s\S]*?<\/div>\s*<\/div>/gi,
];

export function parseGoogleResults(html: string): ParsedGoogleResult[] {
  const candidates = extractCandidates(html);
  const seenUrls = new Set<string>();
  const results: ParsedGoogleResult[] = [];

  for (const candidate of candidates) {
    const url = normalizeResultUrl(candidate.url);
    if (!url || seenUrls.has(url)) {
      continue;
    }

    seenUrls.add(url);
    results.push({
      position: results.length + 1,
      title: normalizeText(candidate.title),
      url,
      content: normalizeText(candidate.content),
    });
  }

  return results;
}

function extractCandidates(html: string): Candidate[] {
  const blocks = unique(extractResultBlocks(html));
  return blocks.flatMap(extractCandidateFromBlock);
}

function extractResultBlocks(html: string): string[] {
  const blocks: string[] = [];
  for (const pattern of blockPatterns) {
    for (const match of html.matchAll(pattern)) {
      blocks.push(match[0]);
    }
  }
  return blocks.length > 0 ? blocks : [html];
}

function extractCandidateFromBlock(block: string): Candidate[] {
  if (isAdBlock(block) || isRelatedBlock(block)) {
    return [];
  }

  const headingMatches = [...block.matchAll(/<h3\b[^>]*>([\s\S]*?)<\/h3>/gi)];
  const candidates: Candidate[] = [];

  for (const headingMatch of headingMatches) {
    const heading = headingMatch[0];
    const title = normalizeText(headingMatch[1] ?? "");
    if (!title) {
      continue;
    }

    const beforeHeading = block.slice(0, Math.max(block.indexOf(heading), 0));
    const afterHeading = block.slice(Math.max(block.indexOf(heading), 0));
    const link = nearestHref(beforeHeading, afterHeading);
    if (!link) {
      continue;
    }

    candidates.push({
      title,
      url: link,
      content: extractSnippet(afterHeading),
    });
  }

  return candidates;
}

function nearestHref(beforeHeading: string, afterHeading: string): string | null {
  const beforeLinks = [...beforeHeading.matchAll(/<a\b[^>]*href=["']([^"']+)["'][^>]*>/gi)];
  const previousLink = beforeLinks.at(-1)?.[1];
  const nextLink = afterHeading.match(/<a\b[^>]*href=["']([^"']+)["'][^>]*>/i)?.[1];
  return previousLink ?? nextLink ?? null;
}

function extractSnippet(html: string): string {
  const snippets = [
    ...html.matchAll(/<div\b[^>]*data-sncf=["']?1["']?[^>]*>([\s\S]*?)<\/div>/gi),
    ...html.matchAll(/<span\b[^>]*>([\s\S]*?)<\/span>/gi),
    ...html.matchAll(/<div\b[^>]*class=["'][^"']*(?:VwiC3b|IsZvec|aCOpRe)[^"']*["'][^>]*>([\s\S]*?)<\/div>/gi),
  ].map((match) => normalizeText(match[1] ?? ""));

  return snippets.find((snippet) => snippet.length > 0 && snippet.length < 1_000) ?? "";
}

export function normalizeResultUrl(rawUrl: string): string | null {
  const decoded = decodeHtml(rawUrl);
  const redirected = extractGoogleRedirect(decoded);

  let url: URL;
  try {
    url = new URL(redirected);
  } catch {
    return null;
  }

  if (!["http:", "https:"].includes(url.protocol)) {
    return null;
  }

  if (isGoogleInternalUrl(url)) {
    return null;
  }

  url.hash = "";
  if ((url.protocol === "http:" && url.port === "80") || (url.protocol === "https:" && url.port === "443")) {
    url.port = "";
  }
  url.hostname = url.hostname.toLowerCase();

  if (url.pathname !== "/" && url.pathname.endsWith("/")) {
    url.pathname = url.pathname.slice(0, -1);
  }

  return url.toString();
}

function extractGoogleRedirect(url: string): string {
  if (!url.startsWith("https://www.google.") && !url.startsWith("https://google.")) {
    return url;
  }

  try {
    const parsed = new URL(url);
    return parsed.searchParams.get("q") ?? parsed.searchParams.get("url") ?? url;
  } catch {
    return url;
  }
}

function isGoogleInternalUrl(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  if (host === "webcache.googleusercontent.com") {
    return true;
  }
  if (!host.endsWith("google.com") && !host.endsWith("google.co.jp")) {
    return false;
  }

  return (
    url.pathname.startsWith("/search") ||
    url.pathname.startsWith("/preferences") ||
    url.pathname.startsWith("/advanced_search") ||
    host === "accounts.google.com" ||
    host === "support.google.com"
  );
}

function isAdBlock(block: string): boolean {
  const text = normalizeText(block).toLowerCase();
  return text.startsWith("広告 ") || text.includes(" sponsored ") || text.includes("スポンサー");
}

function isRelatedBlock(block: string): boolean {
  const text = normalizeText(block).toLowerCase();
  return text.includes("関連検索") || text.includes("他の人はこちらも質問") || text.includes("people also ask");
}

function normalizeText(value: string): string {
  return decodeHtml(stripTags(value)).normalize("NFKC").replace(/\s+/g, " ").trim();
}

function stripTags(html: string): string {
  return html.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ");
}

function decodeHtml(value: string): string {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&nbsp;", " ");
}

function unique(values: string[]): string[] {
  return [...new Set(values)];
}
