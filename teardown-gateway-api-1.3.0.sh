#!/bin/sh

echo "Tearing down Kong using helm"

kubectl delete httproute hello

kubectl delete deployments hello

kubectl delete services hello

kubectl delete gateway kong

kubectl delete gatewayclass kong

kubectl delete gatewayconfiguration kong

helm uninstall kgo -n kong

echo "Cleaned up Kong Gateway resources."

exit 0