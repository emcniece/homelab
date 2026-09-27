# Tailscale K8s operator

Deployed via kustomize from the upstream static manifest, pinned to a release tag:

```sh
kubectl apply -f infra/tailscale/secret.yaml   # gitignored; OAuth client_id/client_secret
kubectl apply -k infra/tailscale
```

To upgrade, bump the tag in **both** the manifest URL and `images[].newTag` in
`kustomization.yaml`, then `kubectl diff -k infra/tailscale` before applying.
The CRDs ship in the same manifest, so keeping the two in lockstep keeps the
CRDs matched to the operator version.

- https://github.com/tailscale/tailscale/blob/main/cmd/k8s-operator/deploy/manifests/operator.yaml
- https://tailscale.com/docs/features/kubernetes-operator
