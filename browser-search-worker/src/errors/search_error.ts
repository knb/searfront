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
