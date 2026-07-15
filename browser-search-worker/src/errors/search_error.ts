export class SearchError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly retryable: boolean,
    public readonly statusCode: number,
    public readonly suspendSeconds?: number,
  ) {
    super(message);
    this.name = "SearchError";
  }
}

export function googleCaptchaError(): SearchError {
  return new SearchError("google_captcha", "Google CAPTCHA page was detected.", false, 429, 86_400);
}

export function googleConsentRequiredError(): SearchError {
  return new SearchError("google_consent_required", "Google consent page was detected.", false, 429);
}

export function googleRateLimitedError(): SearchError {
  return new SearchError(
    "google_rate_limited",
    "Google automated query restriction was detected.",
    false,
    429,
    7_200,
  );
}

export function googleTimeoutError(): SearchError {
  return new SearchError("google_timeout", "Google search timed out.", true, 504);
}

export function googleParseError(): SearchError {
  return new SearchError("google_parse_error", "Google search result page could not be parsed.", true, 502);
}

export function browserlessUnavailableError(): SearchError {
  return new SearchError("browserless_unavailable", "Browserless connection failed.", true, 503);
}
