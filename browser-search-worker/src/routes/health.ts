import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";

type HealthRouteOptions = {
  config: Config;
  browserlessCheck: (config: Config) => Promise<boolean>;
};

export function registerHealthRoute(server: FastifyInstance, options: HealthRouteOptions): void {
  server.get("/health", async (_request, reply) => {
    const reachable = await options.browserlessCheck(options.config);

    if (!reachable) {
      return reply.code(503).send({
        status: "degraded",
        browserless: "unreachable",
      });
    }

    return reply.send({
      status: "ok",
      browserless: "reachable",
    });
  });
}
