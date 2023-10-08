# Homelab

## Deploy Automation

Roles and resources must be configured in the cluster before Github Actions can be used:

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl apply -f ci/gh_actions/
```

Inspiration: https://nicwortel.nl/blog/2022/continuous-deployment-to-kubernetes-with-github-actions
