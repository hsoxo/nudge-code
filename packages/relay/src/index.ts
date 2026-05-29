import { createServer } from 'node:http';
import { FREE_ENTITLEMENT } from '@nudge/protocol-ts';

const port = Number.parseInt(process.env.NUDGE_RELAY_PORT ?? '8787', 10);

const server = createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ ok: true, service: 'nudge-relay' }));
    return;
  }

  if (request.url === '/entitlement/free') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify(FREE_ENTITLEMENT));
    return;
  }

  response.writeHead(404, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ error: 'not_found' }));
});

server.listen(port, () => {
  console.log(`nudge relay placeholder listening on :${port}`);
});
