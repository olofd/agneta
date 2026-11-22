// Foundation WebSocket interoperability against the same stand-in used by the TypeScript suite.
import { createServer } from 'node:http';
import { once } from 'node:events';
import { agnetaLike, standIn } from '../../typescript/test/stand-in.mjs';

const behavior = agnetaLike();
const server = await standIn((message, peer) => {
  if (message.method === 'echo') return { result: { ...message.params, origin: peer.headers.origin ?? null } };
  if (message.method === 'hang') return undefined;
  return behavior.answer(message, peer);
});
const refused = await standIn(undefined, { refuse: true });
const redirect = createServer((request, response) => {
  response.writeHead(302, { Location: server.url.replace('ws:', 'http:') }); response.end();
}).listen(0, '127.0.0.1');
await once(redirect, 'listening');
console.log(JSON.stringify({ url: server.url, refused: refused.url, redirect: `ws://127.0.0.1:${redirect.address().port}/acp` }));
process.stdin.resume();
process.stdin.on('end', async () => {
  await server.close(); await refused.close(); redirect.close();
});
