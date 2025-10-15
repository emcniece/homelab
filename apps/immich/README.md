# Immich Deployment

This directory contains Kubernetes manifests for deploying Immich, a self-hosted photo and video backup solution.

## Architecture

Immich consists of several microservices:

- **immich-server**: Main API server (port 3001)
- **immich-web**: Web frontend (port 3000) 
- **immich-ml**: Machine learning services for face recognition and object detection (port 3001)
- **immich-proxy**: Reverse proxy for serving media files (port 8080)
- **postgres**: PostgreSQL database for metadata storage
- **redis**: Redis for caching and job queues

## Storage

- **immich-library**: Main photo/video storage (100Gi)
- **immich-upload**: Temporary upload storage (50Gi)
- **immich-config**: Configuration and cache storage (10Gi)
- **postgres-data**: Database storage (20Gi)

## Access

The application will be available at: `https://immich.lab.emc2.build`

## Deployment Order

1. `namespace.yaml`
2. `certificate.yaml`
3. `postgres-secret.yaml`
4. `postgres-pvc.yaml`
5. `postgres-deployment.yaml`
6. `postgres-service.yaml`
7. `redis-deployment.yaml`
8. `redis-service.yaml`
9. `immich-library-pvc.yaml`
10. `immich-upload-pvc.yaml`
11. `immich-config-pvc.yaml`
12. `immich-server-deployment.yaml`
13. `immich-server-service.yaml`
14. `immich-web-deployment.yaml`
15. `immich-web-service.yaml`
16. `immich-ml-deployment.yaml`
17. `immich-ml-service.yaml`
18. `immich-proxy-deployment.yaml`
19. `immich-proxy-service.yaml`
20. `immich-ingress.yaml`

## Configuration

The default database credentials are:
- Username: `postgres`
- Password: `postgres123`
- Database: `immich`

**Important**: Change the database password in `postgres-secret.yaml` before deploying to production!

## Resources

- [Immich Documentation](https://immich.app/docs)
- [Immich GitHub](https://github.com/immich-app/immich)
