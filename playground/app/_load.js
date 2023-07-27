const http = require('http');
const querystring = require('querystring');

async function load() {
  const baseOptions = {
    hostname: 'playground-kong',
    port: 8001,
    method: 'POST',
    path: '/services',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    }
  }

  // Add Service
  const service = await request({
    ...baseOptions,
    ...{ path: '/services' },
  }, {
    name: 'destination-service',
    url: 'http://playground-destination-service:3200',
  });

  if (service.code === 5) {
    console.log('Service already exists.')
    process.exit(0)
  }

  // Add Route
  await request({
    ...baseOptions,
    ...{ path: `/services/${service.name}/routes` },
  }, {
    name: 'base',
    paths: ['/'],
  });

  // Add Plugin
  await request({
    ...baseOptions,
    ...{ path: `/services/${service.name}/plugins` },
  }, {
    name: 'the-middleman',
    'config.url': 'http://playground-middle-service:3400',
    'config.forward_headers': true,
    'config.path': '/',
    'config.cache_enabled': true,
    'config.cache_based_on': 'header',
    'config.cache_invalidate_when_streamup_path': ['/invalidate'],
    'config.cache_ttl': 60,
    'config.cache_policy': 'redis',
    'config.redis_host': 'playground-redis',
    'config.redis_database': 0,
  });

  console.log('Playground on Kong created')
}

function request(options, postData) {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let str = ''

      res.setEncoding('utf8');

      res.on('data', function (chunk) {
        str += chunk
      });

      res.on('end', function () {
        resolve(JSON.parse(str))
      });
    })

    req.on('error', function (e) {
      console.error(e);
      process.exit(1);
    });

    req.write(querystring.stringify(postData));
    req.end();
  });
}

try {
  load();
} catch (err) {
  console.error(err);
  process.exit(1);
}
