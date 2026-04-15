#!/usr/bin/env bash

kubectl rollout restart -n istio-gateway deployment/istio-gateway-istio
kubectl rollout restart -n istio-waypoint deployment/istio-waypoint
kubectl rollout restart -n istio-system deployment/prometheus