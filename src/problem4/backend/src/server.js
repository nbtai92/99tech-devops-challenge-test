const http = require("node:http");
const { handler, version } = require("./app");

const port = Number(process.env.PORT || 3000);
const server = http.createServer(handler);

server.listen(port, () => console.log(`backend ${version} listening on ${port}`));

// systemd sends SIGTERM on stop/restart: finish in-flight requests first.
process.on("SIGTERM", () => server.close(() => process.exit(0)));
