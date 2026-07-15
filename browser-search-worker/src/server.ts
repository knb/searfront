import Fastify from "fastify";
import { checkBrowserless } from "./browser.js";
import { loadConfig, type Config } from "./config.js";
import { registerGoogleSearchRoute } from "./routes/google_search.js";
import { registerHealthRoute } from "./routes/health.js";
import type { GoogleSearchDependencies } from "./services/google_search.js";

export type ServerOptions = {
  config?: Config;
  browserlessCheck?: (config: Config) => Promise<boolean>;
  googleSearchDependencies?: GoogleSearchDependencies;
};

export function buildServer(options: ServerOptions = {}) {
  const config = options.config ?? loadConfig();
  const browserlessCheck = options.browserlessCheck ?? checkBrowserless;
  const server = Fastify({ logger: true });

  registerHealthRoute(server, { config, browserlessCheck });
  registerGoogleSearchRoute(server, config, options.googleSearchDependencies);

  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const config = loadConfig();
  const server = buildServer({ config });

  server.listen({ host: "0.0.0.0", port: config.port }).catch((error) => {
    server.log.error(error);
    process.exit(1);
  });
}
