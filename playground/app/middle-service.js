const http = require('http');

const hostname = '0.0.0.0';
const port = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'application/json');

  let body = '{"tenantId": "123", "role": "admin", "accountId": "112233"}';

  /* Print request body */
  let requestBody = []
  req.on('error', (err) => {
    console.error(err);
  }).on('data', (chunk) => {
    requestBody.push(chunk);
  }).on('end', () => {
    requestBody = Buffer.concat(requestBody).toString();
    console.log(requestBody);
  });

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
