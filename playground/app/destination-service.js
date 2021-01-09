const http = require('http');

const hostname = '0.0.0.0';
const port = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');

  let body = 'I\'m the destination service. These are the x-headers added by the-middleman that I can see:\n\n';

  Object.keys(req.headers)
    .filter(e => e.startsWith('x-'))
    .forEach(e => { body += `${e}: ${req.headers[e]}\n` });

  body += '\n';
  body += `@timestamp: ${(new Date()).toISOString()}`;

  res.end(body);
});

server.listen(port, hostname, () => {
  console.log(`Service running on port ${port}`);
});

process.on('SIGINT', () => {
  console.log('Received SIGINT');
  process.exit();
});

process.on('SIGTERM', () => {
  console.log('Received SIGTERM');
  process.exit();
});
