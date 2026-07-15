import type { FastifyInstance } from "fastify";
import { authenticateRequest } from "../auth.js";
import type { Config } from "../config.js";

export function registerGoogleSearchRoute(server: FastifyInstance, config: Config): void {
  server.post("/v1/search/google", { preHandler: authenticateRequest(config) }, async (_request, reply) => {
    return reply.code(501).send({
      status: "error",
      error: {
        code: "not_implemented",
        message: "Google search is not implemented in Phase 1.",
      },
    });
  });
}
