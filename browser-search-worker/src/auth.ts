import type { FastifyReply, FastifyRequest } from "fastify";
import { timingSafeEqual } from "node:crypto";
import type { Config } from "./config.js";

export function authenticateRequest(config: Config) {
  return async function authenticate(request: FastifyRequest, reply: FastifyReply): Promise<void> {
    if (!config.browserWorkerToken) {
      await reply.code(503).send({
        status: "error",
        error: {
          code: "browser_worker_token_not_configured",
          message: "Browser worker token is not configured.",
        },
      });
      return;
    }

    const authorization = request.headers.authorization ?? "";
    const token = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";

    if (!secureEqual(token, config.browserWorkerToken)) {
      await reply.code(401).send({
        status: "error",
        error: {
          code: "unauthorized",
          message: "Bearer token is invalid.",
        },
      });
    }
  };
}

function secureEqual(actual: string, expected: string): boolean {
  const actualBuffer = Buffer.from(actual);
  const expectedBuffer = Buffer.from(expected);

  if (actualBuffer.length !== expectedBuffer.length) {
    return false;
  }

  return timingSafeEqual(actualBuffer, expectedBuffer);
}
