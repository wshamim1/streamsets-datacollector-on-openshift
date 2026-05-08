#!/bin/bash
################################################################################
# StreamSets Data Collector Deployment Script for OpenShift
# This script deploys StreamSets Data Collector engine to OpenShift
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Source CPD variables if available
if [ -f "cpd_vars.sh" ]; then
    source cpd_vars.sh
    print_message "$GREEN" "✓ Loaded CPD configuration variables"
fi

################################################################################
# Configuration Variables
################################################################################

# StreamSets Configuration
export SSET_API_KEY="${SSET_API_KEY:-***}"
export SSET_PROJECT_ID="${SSET_PROJECT_ID:-****}"
export SSET_ENVIRONMENT_ID="${SSET_ENVIRONMENT_ID:-*****}"
export SSET_BASE_URL="${SSET_BASE_URL:-*****}"

# OpenShift Configuration
export STREAMSETS_NAMESPACE="${STREAMSETS_NAMESPACE:-streamsets}"
export STREAMSETS_IMAGE="${STREAMSETS_IMAGE:-icr.io/streamsets/datacollector:JDK17_7.4.0}"
export STREAMSETS_CPU="${STREAMSETS_CPU:-4}"
export STREAMSETS_MEMORY="${STREAMSETS_MEMORY:-8Gi}"
export STREAMSETS_REPLICAS="${STREAMSETS_REPLICAS:-1}"

################################################################################
# Validation
################################################################################

print_message "$BLUE" "=========================================="
print_message "$BLUE" "StreamSets Data Collector Deployment"
print_message "$BLUE" "=========================================="
echo ""

# Check if oc is installed
if ! command -v oc &> /dev/null; then
    print_message "$RED" "✗ Error: 'oc' command not found. Please install OpenShift CLI."
    exit 1
fi

# Check if logged in to OpenShift
if ! oc whoami &> /dev/null; then
    print_message "$RED" "✗ Error: Not logged in to OpenShift cluster."
    print_message "$YELLOW" "Please login using: oc login ${OCP_URL:-<your-cluster-url>}"
    exit 1
fi

print_message "$GREEN" "✓ Connected to OpenShift cluster: $(oc whoami --show-server)"
print_message "$GREEN" "✓ Logged in as: $(oc whoami)"
echo ""

################################################################################
# Create Namespace
################################################################################

print_message "$BLUE" "Creating namespace: ${STREAMSETS_NAMESPACE}"
if oc get namespace ${STREAMSETS_NAMESPACE} &> /dev/null; then
    print_message "$YELLOW" "⚠ Namespace ${STREAMSETS_NAMESPACE} already exists"
else
    oc create namespace ${STREAMSETS_NAMESPACE}
    print_message "$GREEN" "✓ Namespace ${STREAMSETS_NAMESPACE} created"
fi
echo ""

################################################################################
# Create Secret for StreamSets API Key
################################################################################

print_message "$BLUE" "Creating secret for StreamSets credentials..."
oc create secret generic streamsets-credentials \
    --from-literal=api-key="${SSET_API_KEY}" \
    --from-literal=project-id="${SSET_PROJECT_ID}" \
    --from-literal=environment-id="${SSET_ENVIRONMENT_ID}" \
    --from-literal=base-url="${SSET_BASE_URL}" \
    -n ${STREAMSETS_NAMESPACE} \
    --dry-run=client -o yaml | oc apply -f -

print_message "$GREEN" "✓ Secret created/updated"
echo ""

################################################################################
# Create Deployment
################################################################################

print_message "$BLUE" "Creating StreamSets Data Collector deployment..."

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: streamsets-datacollector
  namespace: ${STREAMSETS_NAMESPACE}
  labels:
    app: streamsets-datacollector
    app.kubernetes.io/name: streamsets-datacollector
    app.kubernetes.io/component: data-collector
spec:
  replicas: ${STREAMSETS_REPLICAS}
  selector:
    matchLabels:
      app: streamsets-datacollector
  template:
    metadata:
      labels:
        app: streamsets-datacollector
    spec:
      containers:
      - name: datacollector
        image: ${STREAMSETS_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: SSET_API_KEY
          valueFrom:
            secretKeyRef:
              name: streamsets-credentials
              key: api-key
        - name: SSET_PROJECT_ID
          valueFrom:
            secretKeyRef:
              name: streamsets-credentials
              key: project-id
        - name: SSET_ENVIRONMENT_ID
          valueFrom:
            secretKeyRef:
              name: streamsets-credentials
              key: environment-id
        - name: SSET_BASE_URL
          valueFrom:
            secretKeyRef:
              name: streamsets-credentials
              key: base-url
        resources:
          requests:
            cpu: "${STREAMSETS_CPU}"
            memory: "${STREAMSETS_MEMORY}"
          limits:
            cpu: "${STREAMSETS_CPU}"
            memory: "${STREAMSETS_MEMORY}"
        ports:
        - containerPort: 18630
          name: http
          protocol: TCP
        livenessProbe:
          tcpSocket:
            port: 18630
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 5
        readinessProbe:
          tcpSocket:
            port: 18630
          initialDelaySeconds: 120
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      restartPolicy: Always
EOF

print_message "$GREEN" "✓ Deployment created"
echo ""

################################################################################
# Create Service
################################################################################

print_message "$BLUE" "Creating service for StreamSets Data Collector..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: streamsets-datacollector
  namespace: ${STREAMSETS_NAMESPACE}
  labels:
    app: streamsets-datacollector
spec:
  type: ClusterIP
  ports:
  - port: 18630
    targetPort: 18630
    protocol: TCP
    name: http
  selector:
    app: streamsets-datacollector
EOF

print_message "$GREEN" "✓ Service created"
echo ""

################################################################################
# Create Route (OpenShift specific)
################################################################################

print_message "$BLUE" "Creating route for external access..."

cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: streamsets-datacollector
  namespace: ${STREAMSETS_NAMESPACE}
  labels:
    app: streamsets-datacollector
spec:
  to:
    kind: Service
    name: streamsets-datacollector
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

print_message "$GREEN" "✓ Route created"
echo ""

################################################################################
# Wait for Deployment
################################################################################

print_message "$BLUE" "Waiting for deployment to be ready..."
oc rollout status deployment/streamsets-datacollector -n ${STREAMSETS_NAMESPACE} --timeout=5m

print_message "$GREEN" "✓ Deployment is ready"
echo ""

################################################################################
# Display Information
################################################################################

print_message "$GREEN" "=========================================="
print_message "$GREEN" "StreamSets Data Collector Deployed Successfully!"
print_message "$GREEN" "=========================================="
echo ""

print_message "$BLUE" "Deployment Information:"
echo "  Namespace: ${STREAMSETS_NAMESPACE}"
echo "  Replicas: ${STREAMSETS_REPLICAS}"
echo "  CPU: ${STREAMSETS_CPU}"
echo "  Memory: ${STREAMSETS_MEMORY}"
echo ""

print_message "$BLUE" "Access Information:"
ROUTE_URL=$(oc get route streamsets-datacollector -n ${STREAMSETS_NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo "Route not found")
if [ "$ROUTE_URL" != "Route not found" ]; then
    echo "  External URL: https://${ROUTE_URL}"
else
    echo "  External URL: Not available yet"
fi
echo ""

print_message "$BLUE" "Useful Commands:"
echo "  View pods:        oc get pods -n ${STREAMSETS_NAMESPACE}"
echo "  View logs:        oc logs -f deployment/streamsets-datacollector -n ${STREAMSETS_NAMESPACE}"
echo "  View service:     oc get svc streamsets-datacollector -n ${STREAMSETS_NAMESPACE}"
echo "  View route:       oc get route streamsets-datacollector -n ${STREAMSETS_NAMESPACE}"
echo "  Delete deployment: oc delete all -l app=streamsets-datacollector -n ${STREAMSETS_NAMESPACE}"
echo ""

print_message "$YELLOW" "Note: It may take a few minutes for the StreamSets Data Collector to fully start."
print_message "$YELLOW" "Check the logs if you encounter any issues."
echo ""

