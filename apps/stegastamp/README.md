# stegastamp

Single-page app for encoding/decoding hidden text in images with
[StegaStamp](https://github.com/tancik/StegaStamp).

- Source & image build: https://github.com/emcniece/stegastamp-web
- Image: `ghcr.io/emcniece/stegastamp-web:latest` (multi-arch, model baked in)
- Public URL: https://stegastamp.emc2.build

Stateless — no PVCs. Each replica loads its own copy of the TensorFlow graph
(~1 GB RSS), so scale with `replicas`, not gunicorn workers.

## Deploy

```bash
kubectl apply -f apps/stegastamp/
```

To roll out a new image build:

```bash
kubectl rollout restart deployment/stegastamp-web -n stegastamp
```
