import type { FastifyInstance } from "fastify";
import { authenticateRequest } from "../auth.js";
import type { Config } from "../config.js";
import { SearchError } from "../errors/search_error.js";
import { searchRequestSchema } from "../schemas/search_request.js";
import { searchGoogle, type GoogleSearchDependencies } from "../services/google_search.js";

export function registerGoogleSearchRoute(
  server: FastifyInstance,
  config: Config,
  dependencies: GoogleSearchDependencies = {},
): void {
  server.post("/v1/search/google", { preHandler: authenticateRequest(config) }, async (request, reply) => {
    const parsed = searchRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({
        status: "error",
        error: {
          code: "invalid_request",
          message: "Request body is invalid.",
        },
      });
    }

    try {
      const response = await searchGoogle({ ...parsed.data, requestId: request.id }, config, dependencies);
      return reply.code(200).send(response);
    } catch (error) {
      if (error instanceof SearchError) {
        const blocked = ["google_captcha", "google_consent_required", "google_rate_limited"].includes(error.code);
        return reply.code(error.statusCode).send({
          engine: "google-browser",
          query: parsed.data.query,
          status: blocked ? "blocked" : "error",
          results: [],
          error: {
            code: error.code,
            message: error.message,
            retryable: error.retryable,
            ...(error.suspendSeconds ? { suspend_seconds: error.suspendSeconds } : {}),
          },
          detected: {
            captcha: error.code === "google_captcha",
            consent_page: error.code === "google_consent_required",
            rate_limited: error.code === "google_rate_limited",
          },
          elapsed_ms: 0,
        });
      }

      request.log.error(error);
      return reply.code(500).send({
        status: "error",
        error: {
          code: "internal_error",
          message: "Worker internal error.",
        },
      });
    }
  });
}
