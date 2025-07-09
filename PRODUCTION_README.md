# Bitchat Live - Production Deployment

## 🚀 **LIVE ON MAINNET**

**🌐 Web Application**: https://bitchat.live  
**💬 IRC Server**: wss://irc.bitchat.xyz  
**🚫 Block Service**: https://block.xyz  

## Architecture Overview

The production deployment consists of multiple integrated services:

### Frontend
- **Web IRC Client** at `https://bitchat.live`
- Terminal-style interface with green-on-black aesthetic
- Real-time IRC connections via WebSocket
- Full Swift app feature compatibility

### Backend Services
- **PHP API Server** - REST API with Swift app compatibility
- **IRC Server** - InspIRCd at `irc.bitchat.xyz:6697` (SSL)
- **MySQL Database** - User data and message persistence
- **Redis Cache** - Session management and rate limiting

### Swift App Integration
- **Complete feature parity** with original Swift application
- **Same command structure** (`/help`, `/j`, `/m`, `/w`, etc.)
- **Identical encryption** methods (AES-256-GCM, PBKDF2)
- **Compatible data models** and message formats

## Deployment Components

### 1. Web Application

**Location**: `web/`

- `index.html` - Main interface
- `style.css` - Terminal aesthetic styling
- `config.js` - Production configuration
- `irc-client.js` - IRC WebSocket client
- `networking.js` - Network abstraction layer
- `crypto.js` - Encryption compatibility layer
- `app.js` - Main application logic

**Features**:
- ✅ Real-time IRC messaging
- ✅ Channel management (#general, #tech, #random)
- ✅ Private messaging with @mentions
- ✅ User blocking and favorites
- ✅ Password-protected channels
- ✅ Message encryption
- ✅ Multi-tab synchronization

### 2. PHP Backend

**Location**: `backend/`

- `index.php` - Main API router
- `config.php` - Configuration and database schema
- `classes/SwiftCompatibility.php` - Swift app feature mapping
- `classes/MessageHandler.php` - Message processing
- `classes/UserManager.php` - User management
- `classes/ChannelManager.php` - Channel operations

**API Endpoints**:
- `GET/POST /api/auth` - User authentication
- `GET/POST /api/messages` - Message handling
- `GET/POST /api/channels` - Channel management
- `GET /api/users` - User listing
- `POST /api/block` - User blocking (integrates with block.xyz)
- `GET /api/health` - Health monitoring

### 3. Kubernetes Infrastructure

**Location**: `k8s/`

- `deployment.yaml` - Application deployments
- `services.yaml` - Service definitions and ingress
- Load balancer configuration
- SSL/TLS termination
- Network policies

**Components**:
- **3x Web App Pods** - High availability
- **2x IRC Server Pods** - Redundant IRC service
- **MySQL** - Persistent database
- **Redis** - Caching layer
- **Ingress Controller** - HTTPS termination

## Swift App Compatibility

### Feature Mapping

| Swift Feature | Web Implementation | Status |
|---------------|-------------------|--------|
| **Mesh Networking** | IRC + WebSocket relay | ✅ |
| **Channel Chat** | IRC channels | ✅ |
| **Private Messages** | IRC private messages | ✅ |
| **User Blocking** | API + block.xyz integration | ✅ |
| **Encryption** | AES-256-GCM via Web Crypto API | ✅ |
| **Commands** | Same `/help`, `/j`, `/m`, etc. | ✅ |
| **Message Retention** | Database persistence | ✅ |
| **Emergency Wipe** | Triple-click + API call | ✅ |

### Command Compatibility

```bash
# All original Swift app commands work identically:
/help                    # Show command help
/j #channel              # Join channel
/j #secure password      # Join password-protected channel
/m @user message         # Private message
/w                       # List online users
/channels                # Show joined channels
/nick newname            # Change nickname
/block @user             # Block user
/unblock @user           # Unblock user
/favorite @user          # Toggle favorite
/leave                   # Leave current channel
/clear                   # Clear messages
/back                    # Return to public chat
```

## Production Deployment

### Prerequisites

- Kubernetes cluster with ingress controller
- Docker registry access
- DNS configuration for `bitchat.live` and `irc.bitchat.xyz`
- SSL certificates (Let's Encrypt recommended)

### Quick Deploy

```bash
# Clone repository
git clone <repository-url>
cd bitchat

# Make deployment script executable
chmod +x deploy.sh

# Set environment variables (optional)
export DOCKER_REGISTRY="your-registry.com"
export BLOCK_XYZ_API_KEY="your-block-xyz-key"

# Deploy to production
./deploy.sh
```

### Manual Deployment

```bash
# 1. Create namespace
kubectl create namespace bitchat

# 2. Create secrets
kubectl create secret generic bitchat-secrets \
  --namespace=bitchat \
  --from-literal=db-password="$(openssl rand -base64 32)" \
  --from-literal=mysql-root-password="$(openssl rand -base64 32)" \
  --from-literal=redis-password="$(openssl rand -base64 32)"

# 3. Apply configurations
kubectl apply -f k8s/

# 4. Wait for deployment
kubectl rollout status deployment/bitchat-web-app -n bitchat
```

## Monitoring and Operations

### Health Checks

```bash
# Application health
curl https://bitchat.live/api/health

# Kubernetes status
kubectl get pods -n bitchat
kubectl get services -n bitchat
kubectl get ingress -n bitchat
```

### Logs

```bash
# Web application logs
kubectl logs -f deployment/bitchat-web-app -n bitchat

# IRC server logs
kubectl logs -f deployment/bitchat-irc-server -n bitchat

# Database logs
kubectl logs -f deployment/bitchat-mysql -n bitchat
```

### Metrics

- **Prometheus scraping** enabled on port 8080
- **Application metrics** at `/metrics` endpoint
- **Health monitoring** via readiness/liveness probes

## Security

### Network Security
- **TLS 1.3** encryption for all HTTPS traffic
- **WebSocket Secure (WSS)** for IRC connections
- **Network policies** restricting inter-pod communication
- **CORS** properly configured for cross-origin requests

### Application Security
- **Rate limiting** on API endpoints (30 requests/minute)
- **Input validation** for all user data
- **SQL injection** protection via prepared statements
- **XSS protection** through proper output encoding
- **Password hashing** using bcrypt/Argon2

### Data Protection
- **End-to-end encryption** for private messages
- **Channel password protection** with key derivation
- **User blocking** with block.xyz integration
- **Emergency wipe** functionality preserved

## Integration Services

### IRC Server (irc.bitchat.xyz)
- **InspIRCd** with WebSocket support
- **SSL/TLS** on port 6697
- **Channel management** synchronized with web app
- **User authentication** linked to main database

### Block Service (block.xyz)
- **User reporting** API integration
- **Blocklist synchronization** across platforms
- **Abuse prevention** coordination
- **Community moderation** tools

## Performance

### Scaling
- **Horizontal pod autoscaling** configured
- **Database connection pooling** optimized
- **CDN integration** for static assets
- **Redis caching** for frequently accessed data

### Optimization
- **Message compression** via LZ4 (JavaScript)
- **Connection multiplexing** for IRC
- **Lazy loading** of message history
- **Efficient DOM updates** in web interface

## Development vs Production

| Aspect | Development | Production |
|--------|-------------|------------|
| **URL** | localhost:8080 | https://bitchat.live |
| **IRC** | BroadcastChannel simulation | Real IRC server |
| **Database** | SQLite/Memory | MySQL cluster |
| **SSL** | Self-signed | Let's Encrypt |
| **Scaling** | Single instance | Multi-pod HA |
| **Monitoring** | Console logs | Prometheus/Grafana |

## Troubleshooting

### Common Issues

**Connection Problems**:
```bash
# Check IRC server connectivity
kubectl exec -it deployment/bitchat-irc-server -n bitchat -- nc -zv localhost 6697

# Verify web service
kubectl port-forward service/bitchat-web-service 8080:80 -n bitchat
curl http://localhost:8080/api/health
```

**Database Issues**:
```bash
# Check MySQL status
kubectl exec -it deployment/bitchat-mysql -n bitchat -- mysql -u root -p

# View database logs
kubectl logs deployment/bitchat-mysql -n bitchat
```

**SSL Certificate Issues**:
```bash
# Check certificate status
kubectl describe certificate bitchat-tls-cert -n bitchat

# Verify ingress
kubectl describe ingress bitchat-web-ingress -n bitchat
```

### Support Commands

```bash
# Full system status
kubectl get all -n bitchat

# Event debugging
kubectl get events -n bitchat --sort-by='.lastTimestamp'

# Resource usage
kubectl top pods -n bitchat

# Configuration verification
kubectl get configmaps -n bitchat
kubectl get secrets -n bitchat
```

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Contributing

1. **Test locally** using the development setup
2. **Ensure Swift compatibility** - reference original app code
3. **Update both web and backend** components
4. **Test deployment** using the deploy script
5. **Monitor production** impact after changes

---

**🚀 Bitchat Live is now running on mainnet at https://bitchat.live**

**Ready for global decentralized communication!** 🌍💬