const http = require("http");

const routes = {
  "/": () => "Hello from demo-app",
  "/health": () => JSON.stringify({ ok: true }),
};

http
  .createServer((req, res) => {
    const handler = routes[req.url];
    res.writeHead(handler ? 200 : 404);
    res.end(handler ? handler() : "Not found");
  })
  .listen(3000);
