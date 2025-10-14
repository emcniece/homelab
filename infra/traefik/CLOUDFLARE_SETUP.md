# Cloudflare DNS Verification Setup

This guide explains how to configure Cloudflare DNS verification for Let's Encrypt certificates using cert-manager.

## Prerequisites

1. **Cloudflare Account**: You need a Cloudflare account with DNS management access
2. **Domain**: Your domain must be managed by Cloudflare DNS
3. **API Token**: Cloudflare API token with DNS edit permissions

## Step 1: Create Cloudflare API Token

1. Log in to your Cloudflare dashboard
2. Go to "My Profile" → "API Tokens"
3. Click "Create Token"
4. Use the "Custom token" template
5. Configure the token with these permissions:
   - **Zone**: `Zone:Read` for your domain
   - **Zone**: `DNS:Edit` for your domain
6. Set the zone resources to include your domain (e.g., `lab.emc2.build`)
7. Click "Continue to summary" and then "Create Token"
8. **Important**: Copy the token immediately as it won't be shown again

## Step 2: Update the Secret

Edit the `cloudflare-secret.yaml` file and replace `YOUR_CLOUDFLARE_API_TOKEN_HERE` with your actual API token:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "your-actual-cloudflare-api-token-here"
```

## Step 3: Apply the Configuration

```bash
# Apply the Cloudflare secret
kubectl apply -f cloudflare-secret.yaml

# Apply the updated ClusterIssuers
kubectl apply -f cluster-issuer.yaml
```

## Step 4: Test the Configuration

1. Update your ingress to use the Let's Encrypt staging issuer:
   ```bash
   kubectl annotate ingress test-ingress -n test-app cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite
   ```

2. Delete the existing certificate to force a new one:
   ```bash
   kubectl delete certificate test-tls -n test-app
   ```

3. Monitor the certificate creation:
   ```bash
   kubectl get certificates -n test-app -w
   ```

## How DNS01 Challenge Works

1. **Certificate Request**: When a certificate is requested, cert-manager creates a DNS TXT record
2. **DNS Verification**: Let's Encrypt queries the DNS record to verify domain ownership
3. **Certificate Issuance**: Once verified, the certificate is issued
4. **Cleanup**: The temporary DNS record is removed

## Benefits of DNS01 Challenge

- **No Network Issues**: Bypasses HTTP connectivity problems
- **Wildcard Support**: Can issue wildcard certificates (*.lab.emc2.build)
- **Internal Services**: Works for services not exposed to the internet
- **No Port 80/443**: Doesn't require HTTP endpoints to be accessible

## Troubleshooting

### Check ClusterIssuer Status
```bash
kubectl describe clusterissuer letsencrypt-staging
```

### Check Certificate Status
```bash
kubectl describe certificate test-tls -n test-app
```

### Check Challenge Status
```bash
kubectl get challenges -A
kubectl describe challenge <challenge-name> -n <namespace>
```

### Common Issues

1. **Invalid API Token**: Check token permissions and zone access
2. **DNS Propagation**: DNS changes may take time to propagate
3. **Rate Limits**: Let's Encrypt has rate limits (staging has higher limits)

## Security Notes

- Store the API token securely
- Use least-privilege permissions
- Consider using Cloudflare API keys instead of global API keys
- Monitor certificate issuance logs

## Production vs Staging

- **Staging**: Use `letsencrypt-staging` for testing (higher rate limits)
- **Production**: Use `letsencrypt-prod` for live certificates
- **Switch**: Change the ingress annotation when ready for production
