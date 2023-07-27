# The Middleman Playground

Check `the-middleman` working.

## Description

The docker-composer will start a `postgres`, `redis`, `kong`, `the-middleman`, a example of `middle-service` and a example of `destination-service`.

## Playing

Run:

```bash
docker-compose up
```

You'll get some errors message until the services go on. When everything is up run:

```bash
curl http://localhost:8000
```

The middleman is adding the following headers: `x-middleman-cache-status`, `x-account-id`, `x-tenant-id` and `x-role`.

To easily check your kong service, access [http://localhost:1337](http://localhost:1337). Login/Password: `admin`/`adminadminadmin`. On your first access, click on *Connections* and *connection icon*.

## Author

Udlei Nati - [GitHub](https://github.com/udleinati "GitHub") - [LinkedIn](https://www.linkedin.com/in/udleinati/ "LinkedIn")
