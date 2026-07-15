import { z } from "zod";

export const searchRequestSchema = z
  .object({
    query: z.string().trim().min(1).max(500),
    language: z.string().default("ja"),
    country: z.string().default("JP"),
    limit: z.number().int().min(1).max(10).default(10),
  })
  .strict();

export type SearchRequest = z.infer<typeof searchRequestSchema>;
