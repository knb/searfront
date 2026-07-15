export class RateLimiter {
  private lastRunAt = 0;

  constructor(
    private readonly minIntervalMs: number,
    private readonly jitterMs: number,
  ) {}

  async wait(): Promise<void> {
    const elapsed = Date.now() - this.lastRunAt;
    const jitter = this.jitterMs > 0 ? Math.floor(Math.random() * this.jitterMs) : 0;
    const delay = Math.max(this.minIntervalMs - elapsed, 0) + jitter;

    if (delay > 0) {
      await new Promise((resolve) => setTimeout(resolve, delay));
    }

    this.lastRunAt = Date.now();
  }
}
