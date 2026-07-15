import { z } from "zod";

export const searchResultSchema = z.object({
  position: z.number().int().positive(),
  title: z.string(),
  url: z.string().url(),
  content: z.string(),
});

export const searchResponseSchema = z.object({
  engine: z.literal("google-browser"),
  query: z.string(),
  status: z.enum(["ok", "empty", "blocked", "error"]),
  results: z.array(searchResultSchema),
  error: z
    .object({
      code: z.string(),
      message: z.string(),
      retryable: z.boolean(),
      suspend_seconds: z.number().int().positive().optional(),
    })
    .optional(),
  detected: z.object({
    captcha: z.boolean(),
    consent_page: z.boolean(),
    rate_limited: z.boolean(),
  }),
  elapsed_ms: z.number().int().nonnegative(),
});

export type SearchResponse = z.infer<typeof searchResponseSchema>;
