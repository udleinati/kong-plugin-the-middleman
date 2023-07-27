# The Middleman

A Kong plugin that enables an extra HTTP POST/GET request - `the-middle-request` - before proxing to the original request.

## Description

In some cases, you may need to validate your requests using a separeted HTTP service.

For every incoming request, you might forward the `path`, `host`, `headers` and `body` to your `the-middle-request`. The `the-middle-request` might be cached and the body response might be injected into the original header request.

This project was inspered by [kong-external-auth](https://github.com/jcramalho/kong-external-auth "kong-external-auth") and [kong-middleman-plugin](https://github.com/pantsel/kong-middleman-plugin "kong-middleman-plugin").

## Installation

```bash
$ luarocks install kong-plugin-the-middleman
```

Update the `plugins` config to add `the-middleman`:

```
plugins = bundled,the-middleman
```

## Use cases

Check the [playground](https://github.com/udleinati/kong-plugin-the-middleman/tree/master/playground "playground") to see `the-middleman` working.

### Host offloading

You might need to identify your client by `host` with some custom logic and adding information to the request header. I call this process `host-offloading`. Follow the steps to do it:

1. Receive requests from www.domain1.com and www.domain2.com;
2. `the-middleman` will send `the-middle-request` to some service;
3. The service will check the `x-forwared-host` header and return a JSON with a `domainId` property;
4. `the-middleman` will add the `domainId` to the original header: `x-domain-id`;
5. The destination service doesn't need to offload the host. It needs to get the data needed from the header.

### Inject user data into the header

1. Request with some JWT;
2. `the-middleman` will send `the-middle-request` to some service;
3. The service will validate the JWT, perform some custom logic and return a JSON with `role` and `userId` properties;
4. `the-middleman` will add the `role` and `userId` to the original header: `x-role` and `x-user-id`;
5. The destination service doesn't need to validate the JWT, just rely on the headers `x-role` and `x-user-id`.

## Configuration

You can add the plugin on top of an API by executing the following request on your Kong server:

```bash
$ curl -X POST http://kong:8001/apis/{api}/plugins \
    --data "name=the-middleman" \
    --data "config.url=http://myservice"
```

| Parameter | default | description |
| ---       | ---     | ---         |
| `config.url` | [required] | Service where the requests will be made. |
| `config.path` |  | Path on service where the requests will be made. |
| `config.method` | POST | Allowed values: `POST` and `GET`. |
| `config.connect_timeout` | 5000 | Connection timeout (in ms) to the provided url. |
| `config.send_timeout` | 10000 | Send timeout (in ms) to the provided url. |
| `config.read_timeout` | 10000 | Read timeout (in ms) to the provided url. |
| `config.forward_headers` | false | Forward the request headers to `the-middle-request` body. |
| `config.forward_path` | false | Forward the request path to `the-middle-request` body. |
| `config.forward_query` | false | Forward the request query to `the-middle-request` body. |
| `config.forward_body` | false | Forward the request body to `the-middle-request` body. |
| `config.inject_body_response_into_header` | true | Inject `the-middle-request` response into the request header. Note: The response MUST BE a JSON and the property key will be dasherized (kebab-case).  |
| `config.injected_header_prefix` | X- | Prefix to the injected headers. |
| `config.streamdown_injected_headers` | false | When this option is enabled, `the-middleman` will add to the response header all headers added by `the-middleman` and by the middle-service. |
| `config.cache_enabled` | false | Add cache to `the-middle-request`. When on a header `x-middleman-cache-status` will be added, the value might be *HIT* or *MISS*. |
| `config.cache_based_on` | host | Allowed values: `host`, `host-path`, `host-path-query` or `header` |
| `config.cache_based_on_headers` | authorization | The header names that will be used to cache. Valid just when `cache_based_on` is `header`. It is possible to pass more than one header with commma, for example, `header1,header2`, the first header will be prioritized. If it is unavailable, the second one will be cached, and so on. |
| `config.cache_invalidate_when_streamup_path` | [] | The cache will be invalidate when the request access the `path`. No matter the statuscode that it will return. |
| `config.cache_ttl` | 60 | TTL |
| `config.cache_policy` | local | Allowed values: `local` or `redis` |
| `config.redis_host` |  | Mandatory. |
| `config.redis_port` | 6379 | |
| `config.redis_password` | | |
| `config.redis_username` | | |
| `config.redis_ssl` | false | |
| `config.redis_ssl_verify` | false | |
| `config.redis_timeout` | 2000 | |
| `config.redis_database` | 0 | |

## Author

Udlei Nati - [GitHub](https://github.com/udleinati "GitHub") - [LinkedIn](https://www.linkedin.com/in/udleinati/ "LinkedIn")
