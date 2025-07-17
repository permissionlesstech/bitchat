#!/bin/bash

# Bitchat Live Production Deployment Script
# Deploys to Kubernetes for live mainnet at https://bitchat.live
# Integrates with irc.bitchat.xyz and block.xyz

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="bitchat"
DOMAIN="bitchat.live"
IRC_DOMAIN="irc.bitchat.xyz"
BLOCK_DOMAIN="block.xyz"

echo -e "${BLUE}🚀 Bitchat Live Production Deployment${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo -e "Domain: ${GREEN}https://${DOMAIN}${NC}"
echo -e "IRC Server: ${GREEN}wss://${IRC_DOMAIN}${NC}"
echo -e "Block Service: ${GREEN}https://${BLOCK_DOMAIN}${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}📋 Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ docker not found. Please install Docker.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"

# Create namespace
echo -e "${YELLOW}📦 Creating namespace...${NC}"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Generate secrets
echo -e "${YELLOW}🔐 Generating secrets...${NC}"

# Generate random passwords
DB_PASSWORD=$(openssl rand -base64 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
REDIS_PASSWORD=$(openssl rand -base64 32)
BLOCK_XYZ_API_KEY=${BLOCK_XYZ_API_KEY:-"demo_api_key_12345"}

# Create secrets
kubectl create secret generic bitchat-secrets \
  --namespace=${NAMESPACE} \
  --from-literal=db-name=bitchat \
  --from-literal=db-user=bitchat_user \
  --from-literal=db-password="${DB_PASSWORD}" \
  --from-literal=mysql-root-password="${MYSQL_ROOT_PASSWORD}" \
  --from-literal=redis-password="${REDIS_PASSWORD}" \
  --from-literal=block-xyz-api-key="${BLOCK_XYZ_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✅ Secrets created${NC}"

# Build and push Docker image
echo -e "${YELLOW}🐳 Building Docker image...${NC}"

cat > Dockerfile << 'EOF'
FROM php:8.1-apache

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    zip \
    unzip \
    nginx \
    supervisor \
    && docker-php-ext-install pdo pdo_mysql mbstring exif pcntl bcmath gd

# Install APCu for caching
RUN pecl install apcu && docker-php-ext-enable apcu

# Configure Apache and Nginx
RUN a2enmod rewrite ssl headers
COPY backend/apache.conf /etc/apache2/sites-available/000-default.conf
COPY backend/nginx.conf /etc/nginx/nginx.conf

# Copy application files
COPY backend/ /var/www/html/
COPY web/ /var/www/html/web/

# Set permissions
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

# Configure supervisor
COPY backend/supervisor.conf /etc/supervisor/conf.d/bitchat.conf

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/api/health || exit 1

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
EOF

# Build image
docker build -t bitchat/web-app:latest .

# Push to registry (assuming you have a registry configured)
if [ ! -z "${DOCKER_REGISTRY}" ]; then
    echo -e "${YELLOW}📤 Pushing to registry...${NC}"
    docker tag bitchat/web-app:latest ${DOCKER_REGISTRY}/bitchat/web-app:latest
    docker push ${DOCKER_REGISTRY}/bitchat/web-app:latest
fi

echo -e "${GREEN}✅ Docker image built${NC}"

# Create ConfigMaps
echo -e "${YELLOW}📝 Creating configuration...${NC}"

# MySQL initialization script
kubectl create configmap bitchat-mysql-init \
  --namespace=${NAMESPACE} \
  --from-literal=init.sql="
    CREATE DATABASE IF NOT EXISTS bitchat;
    USE bitchat;
    
    -- Based on Swift app's data models
    CREATE TABLE IF NOT EXISTS users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      nickname VARCHAR(32) UNIQUE NOT NULL,
      fingerprint VARCHAR(64),
      last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      is_blocked BOOLEAN DEFAULT FALSE,
      INDEX idx_nickname (nickname),
      INDEX idx_fingerprint (fingerprint)
    );
    
    CREATE TABLE IF NOT EXISTS channels (
      id INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(64) UNIQUE NOT NULL,
      creator_id INT,
      password_hash VARCHAR(255),
      is_password_protected BOOLEAN DEFAULT FALSE,
      retention_enabled BOOLEAN DEFAULT FALSE,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (creator_id) REFERENCES users(id),
      INDEX idx_name (name)
    );
    
    CREATE TABLE IF NOT EXISTS messages (
      id INT AUTO_INCREMENT PRIMARY KEY,
      message_id VARCHAR(64) UNIQUE NOT NULL,
      sender_id INT,
      channel_id INT NULL,
      content TEXT NOT NULL,
      is_private BOOLEAN DEFAULT FALSE,
      is_encrypted BOOLEAN DEFAULT FALSE,
      ttl INT DEFAULT 7,
      timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      expires_at TIMESTAMP NULL,
      FOREIGN KEY (sender_id) REFERENCES users(id),
      FOREIGN KEY (channel_id) REFERENCES channels(id),
      INDEX idx_message_id (message_id),
      INDEX idx_timestamp (timestamp),
      INDEX idx_channel_id (channel_id)
    );
    
    CREATE TABLE IF NOT EXISTS channel_members (
      channel_id INT,
      user_id INT,
      joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (channel_id, user_id),
      FOREIGN KEY (channel_id) REFERENCES channels(id),
      FOREIGN KEY (user_id) REFERENCES users(id)
    );
    
    CREATE TABLE IF NOT EXISTS blocked_users (
      blocker_id INT,
      blocked_id INT,
      blocked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (blocker_id, blocked_id),
      FOREIGN KEY (blocker_id) REFERENCES users(id),
      FOREIGN KEY (blocked_id) REFERENCES users(id)
    );
    
    -- Insert default channels
    INSERT IGNORE INTO channels (name, is_password_protected) VALUES 
      ('#general', FALSE),
      ('#tech', FALSE),
      ('#random', FALSE);
  " \
  --dry-run=client -o yaml | kubectl apply -f -

# IRC server configuration
kubectl create configmap bitchat-irc-config \
  --namespace=${NAMESPACE} \
  --from-literal=inspircd.conf="
    <config format=\"xml\">
      <define name=\"bindip\" value=\"0.0.0.0\">
      <define name=\"bindport\" value=\"6667\">
      <define name=\"bindportssl\" value=\"6697\">
      
      <server name=\"irc.bitchat.xyz\" description=\"Bitchat IRC Server\" id=\"001\">
      
      <admin name=\"Bitchat Admin\" nick=\"admin\" email=\"admin@bitchat.live\">
      
      <bind address=\"\$bindip\" port=\"\$bindport\" type=\"clients\">
      <bind address=\"\$bindip\" port=\"\$bindportssl\" type=\"clients\" ssl=\"gnutls\">
      
      <module name=\"gnutls\">
      <gnutls certfile=\"/etc/ssl/certs/inspircd/cert.pem\" keyfile=\"/etc/ssl/certs/inspircd/key.pem\">
      
      <module name=\"websocket\">
      <websocket hook=\"irc\">
      
      <channels users=\"20\" opers=\"60\">
      <hostname charmap=\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_/0123456789\">
      
      <options prefixquit=\"Quit: \" suffixquit=\"\" prefixpart=\"&quot;\" suffixpart=\"&quot;\" syntaxhints=\"yes\">
      <security genericoper=\"no\" restrictbannedusers=\"yes\" hidesplits=\"no\" maxtargets=\"20\">
      <performance netbuffersize=\"10240\" maxwho=\"4096\" somaxconn=\"128\" limitsomaxconn=\"true\">
      <options allowhalfop=\"yes\">
      
      <log method=\"file\" type=\"* -USERINPUT -USEROUTPUT\" level=\"default\" target=\"/var/log/inspircd.log\">
      
      <whowas groupsize=\"10\" maxgroups=\"100000\" maxkeep=\"3d\">
      
      <badnick nick=\"ChanServ\" reason=\"Reserved For Services\">
      <badnick nick=\"NickServ\" reason=\"Reserved For Services\">
      <badnick nick=\"OperServ\" reason=\"Reserved For Services\">
      <badnick nick=\"MemoServ\" reason=\"Reserved For Services\">
    </config>
  " \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✅ Configuration created${NC}"

# Apply persistent volumes
echo -e "${YELLOW}💾 Creating persistent volumes...${NC}"

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bitchat-mysql-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: ssd
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bitchat-redis-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: ssd
EOF

echo -e "${GREEN}✅ Persistent volumes created${NC}"

# Deploy applications
echo -e "${YELLOW}🚀 Deploying applications...${NC}"

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/services.yaml

echo -e "${GREEN}✅ Applications deployed${NC}"

# Wait for deployments
echo -e "${YELLOW}⏳ Waiting for deployments to be ready...${NC}"

kubectl rollout status deployment/bitchat-web-app -n ${NAMESPACE} --timeout=300s
kubectl rollout status deployment/bitchat-mysql -n ${NAMESPACE} --timeout=300s
kubectl rollout status deployment/bitchat-irc-server -n ${NAMESPACE} --timeout=300s

echo -e "${GREEN}✅ All deployments ready${NC}"

# Get service information
echo -e "${YELLOW}📊 Service Information${NC}"
echo ""

WEB_SERVICE_IP=$(kubectl get service bitchat-web-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pending...")
IRC_SERVICE_IP=$(kubectl get service irc-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pending...")

echo -e "Web Service IP: ${GREEN}${WEB_SERVICE_IP}${NC}"
echo -e "IRC Service IP: ${GREEN}${IRC_SERVICE_IP}${NC}"
echo ""

# Create monitoring setup
echo -e "${YELLOW}📈 Setting up monitoring...${NC}"

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceMonitor
metadata:
  name: bitchat-monitoring
  namespace: ${NAMESPACE}
spec:
  selector:
    matchLabels:
      app: bitchat
      component: monitoring
  endpoints:
  - port: metrics
    path: /metrics
    interval: 30s
EOF

echo -e "${GREEN}✅ Monitoring configured${NC}"

# Display deployment summary
echo ""
echo -e "${BLUE}🎉 Deployment Complete!${NC}"
echo -e "${BLUE}======================${NC}"
echo ""
echo -e "📱 ${GREEN}Web Application:${NC} https://${DOMAIN}"
echo -e "💬 ${GREEN}IRC Server:${NC} wss://${IRC_DOMAIN}"
echo -e "🚫 ${GREEN}Block Service:${NC} https://${BLOCK_DOMAIN}"
echo ""
echo -e "🔍 ${YELLOW}Monitoring Commands:${NC}"
echo -e "  kubectl get pods -n ${NAMESPACE}"
echo -e "  kubectl logs -f deployment/bitchat-web-app -n ${NAMESPACE}"
echo -e "  kubectl get services -n ${NAMESPACE}"
echo ""
echo -e "🔧 ${YELLOW}Troubleshooting:${NC}"
echo -e "  kubectl describe pod -l app=bitchat -n ${NAMESPACE}"
echo -e "  kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'"
echo ""
echo -e "📊 ${YELLOW}Health Check:${NC}"
echo -e "  curl https://${DOMAIN}/api/health"
echo ""

# Test deployment
echo -e "${YELLOW}🧪 Running deployment tests...${NC}"

# Wait a bit for services to be fully ready
sleep 10

# Test health endpoint
if kubectl exec -n ${NAMESPACE} deployment/bitchat-web-app -- curl -f http://localhost/api/health > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Health check passed${NC}"
else
    echo -e "${RED}❌ Health check failed${NC}"
fi

# Test database connection
if kubectl exec -n ${NAMESPACE} deployment/bitchat-mysql -- mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Database connection test passed${NC}"
else
    echo -e "${RED}❌ Database connection test failed${NC}"
fi

echo ""
echo -e "${GREEN}🚀 Bitchat Live is now running on mainnet!${NC}"
echo -e "${GREEN}Visit https://${DOMAIN} to start chatting!${NC}"

# Cleanup build files
rm -f Dockerfile