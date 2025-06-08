#!/bin/sh

echo "Installing Kong using helm"

# Check if the tools exists
if ! command -v kubectl 2>/dev/null; then
  echo "Error: kubectl was not found. Please ensure it is installed and in your PATH." >&2
  exit 1
fi

if ! command -v helm 2>/dev/null; then
  echo "Error: helm was not found. Please ensure it is installed and in your PATH." >&2
  exit 1
fi

# Check if kubectl can connect to the cluster
if ! kubectl get nodes &> /dev/null; then
  echo "Error: Failed to connect to the cluster.  Check your kubeconfig."
  exit 1
fi

# Check the status of the cluster nodes
echo "Checking cluster health:"
kubectl get nodes -o json | jq -r '.items[] | .status.conditions[] | select(.type == "Ready") | .status' | grep -q "True" && echo "Cluster is healthy." || echo "Cluster is not healthy.  Check node statuses."

echo "Applying Gateway API standard installation..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

echo "Adding Kong Helm repository..."
if ! helm repo list | grep -q kong; then
  echo "Adding Kong Helm repository..."
  helm repo add kong https://charts.konghq.com
else
  echo "Kong Helm repository already exists."
fi

echo "Updating Kong Helm repository..."
helm repo update kong

echo "Installing Kong Gateway Operator..."
helm upgrade --install kgo kong/gateway-operator -n kong --create-namespace --set image.tag=1.6.1 --set kubernetes-configuration-crds.enabled=true --set env.ENABLE_CONTROLLER_KONNECT=true

sleep 10
echo "Creating Gateway Configuration..."

echo 'kind: GatewayConfiguration
apiVersion: gateway-operator.konghq.com/v1beta1
metadata:
 name: kong
 namespace: default
spec:
 dataPlaneOptions:
   deployment:
     podTemplateSpec:
       spec:
         containers:
         - name: proxy
           image: kong:3.9.1
 controlPlaneOptions:
   deployment:
     podTemplateSpec:
       spec:
         containers:
         - name: controller
           image: kong/kubernetes-ingress-controller:3.4.4
           env:
           - name: CONTROLLER_LOG_LEVEL
             value: debug' | kubectl apply -f -

echo "Creating GatewayClass and Gateway..."

echo '
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1
metadata:
 name: kong
spec:
 controllerName: konghq.com/gateway-operator
 parametersRef:
   group: gateway-operator.konghq.com
   kind: GatewayConfiguration
   name: kong
   namespace: default
---
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
 name: kong
 namespace: default
spec:
 gatewayClassName: kong
 listeners:
 - name: http
   protocol: HTTP
   port: 80' | kubectl apply -f -

echo "Verifying GatewayClass and Gateway creation..."
sleep 5
kubectl get gateway kong -o wide

echo "Creating a Service for the Gateway..."

echo '
apiVersion: v1
kind: Service
metadata:
  labels:
    app: hello
  name: hello
spec:
  ports:
  - port: 8080
    name: tcp
    protocol: TCP
    targetPort: 8080
  selector:
    app: hello
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: hello
  name: hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello
  strategy: {}
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - image: apiprimer/hello-go:latest
        name: hello
        ports:
        - containerPort: 8080
        resources: {}
' | kubectl apply -f -

echo "Creating Route for the Gateway..."

echo '
kind: HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
metadata:
 name: hello
spec:
 parentRefs:
   - group: gateway.networking.k8s.io
     kind: Gateway
     name: kong
 rules:
   - matches:
       - path:
           type: PathPrefix
           value: /hello
     backendRefs:
       - name: hello
         port: 8080
' | kubectl apply -f -

echo "Waiting for the Gateway to be ready..."
sleep 20

export PROXY_IP=$(kubectl get gateway kong -n default -o jsonpath='{.status.addresses[0].value}')

echo "Gateway API setup complete. You can now access the service at http://$PROXY_IP/hello"

echo "To access the service, you can use the following command:"
echo "curl http://$PROXY_IP:80/hello"

echo "To tear down the setup, run the teardown script: curl -Ls https://raw.githubusercontent.com/kong-tools/scripts/refs/heads/main/teardown-gateway-api-1.3.0.sh | bash"
exit 0