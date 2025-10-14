# UDM Pro Configuration for home.emc2.build

## Current Status
- ✅ Organizr is running on media server (192.168.1.100:9001)
- ✅ DNS resolves home.emc2.build to 192.168.1.100
- ✅ Direct access to 192.168.1.100:9001 works
- ❌ home.emc2.build returns 404 (UDM Pro not configured)

## UDM Pro Configuration Required

The UDM Pro is acting as the primary reverse proxy and needs to be configured to route `home.emc2.build` to the Organizr app on port 9001.

### Option 1: UDM Pro Port Forwarding (Recommended)
Configure a port forwarding rule in the UDM Pro:
- **Source**: Any
- **Destination**: 192.168.1.100:9001
- **Port**: 80
- **Host**: home.emc2.build

### Option 2: UDM Pro Reverse Proxy
If the UDM Pro supports reverse proxy configuration:
- **Host**: home.emc2.build
- **Backend**: 192.168.1.100:9001
- **Protocol**: HTTP

### Option 3: Apache Virtual Host on Media Server
Configure Apache on the media server to serve Organizr on port 80:

```apache
<VirtualHost *:80>
    ServerName home.emc2.build
    ProxyPreserveHost On
    ProxyPass / http://localhost:9001/
    ProxyPassReverse / http://localhost:9001/
    ErrorLog ${APACHE_LOG_DIR}/home.emc2.build_error.log
    CustomLog ${APACHE_LOG_DIR}/home.emc2.build_access.log combined
</VirtualHost>
```

## Next Steps
1. Access UDM Pro web interface
2. Configure port forwarding or reverse proxy for home.emc2.build
3. Test access to https://home.emc2.build/
4. Verify Organizr is accessible

## Testing Commands
```bash
# Test direct access
curl -I http://192.168.1.100:9001

# Test through domain
curl -I http://home.emc2.build

# Test HTTPS (after UDM Pro config)
curl -I https://home.emc2.build
```
