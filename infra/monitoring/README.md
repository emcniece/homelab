# Monitoring Stack

This directory contains Kubernetes manifests for a complete monitoring stack including Prometheus, Grafana, and node_exporter.

## Components

### Prometheus
- **Deployment**: `prometheus-deployment.yaml` - Main Prometheus server
- **Service**: `prometheus-service.yaml` - ClusterIP service for Prometheus
- **ConfigMap**: `prometheus-configmap.yaml` - Prometheus configuration
- **PVC**: `prometheus-pvc.yaml` - Persistent storage for metrics data
- **ServiceAccount**: `prometheus-serviceaccount.yaml` - RBAC for Prometheus

### Grafana
- **Deployment**: `grafana-deployment.yaml` - Grafana dashboard server
- **Service**: `grafana-service.yaml` - ClusterIP service for Grafana
- **ConfigMap**: `grafana-configmap.yaml` - Grafana datasource configuration
- **PVC**: `grafana-pvc.yaml` - Persistent storage for Grafana data
- **Ingress**: `grafana-ingress.yaml` - External access via Traefik

### Node Exporter
- **DaemonSet**: `node-exporter-daemonset.yaml` - Node metrics collection
- **Service**: `node-exporter-service.yaml` - Service for node metrics

### Kube State Metrics
- **Deployment**: `kube-state-metrics-deployment.yaml` - Kubernetes object metrics
- **Service**: `kube-state-metrics-service.yaml` - Service for kube-state-metrics
- **ServiceAccount**: `kube-state-metrics-serviceaccount.yaml` - RBAC for kube-state-metrics

## Deployment

Deploy the entire monitoring stack:

```bash
kubectl apply -k .
```

Or deploy individual components:

```bash
# Deploy namespace first
kubectl apply -f namespace.yaml

# Deploy Prometheus
kubectl apply -f prometheus-*.yaml

# Deploy Grafana
kubectl apply -f grafana-*.yaml

# Deploy node exporter
kubectl apply -f node-exporter-*.yaml

# Deploy kube-state-metrics
kubectl apply -f kube-state-metrics-*.yaml
```

## Access

- **Grafana**: https://grafana.lab.emc2.build (admin/admin)
- **Prometheus**: Access via port-forward: `kubectl port-forward -n monitoring svc/prometheus 9090:9090`

## Storage

The monitoring stack uses the `ceph-rbd` storage class for persistent volumes. Ensure this storage class is available in your cluster.

## Configuration

### Prometheus
- Retention: 3 days
- Scrape interval: 30s
- Monitors: Kubernetes API, nodes, pods, services, and custom applications

### Grafana
- Pre-configured with Prometheus datasource
- Default admin credentials: admin/admin
- Persistent storage for dashboards and configuration

### Node Exporter
- Collects system metrics from all nodes
- Excludes certain filesystem types and mount points
- Runs with appropriate security context

## Monitoring Targets

The Prometheus configuration automatically discovers and monitors:
- Kubernetes API server
- Kubernetes nodes (via kubelet)
- Kubernetes pods (via cAdvisor)
- Node exporter metrics
- Kube-state-metrics
- Services with `prometheus.io/scrape: "true"` annotation

## Customization

To add custom monitoring targets, modify the `prometheus-configmap.yaml` file and add new scrape configurations.

To add custom dashboards to Grafana, you can:
1. Import dashboards through the Grafana UI
2. Add dashboard JSON files to a ConfigMap and mount them
3. Use Grafana's provisioning system for automated dashboard deployment
