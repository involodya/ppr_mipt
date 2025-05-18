#!/bin/bash

set -e

if ! command -v istioctl &> /dev/null
then
    echo "istioctl не найден, устанавливаю Istio CLI..."
    curl -L https://istio.io/downloadIstio | sh -
    cd istio-*
    export PATH=$PWD/bin:$PATH
fi

echo "Устанавливаю Istio в кластер..."
istioctl install --set profile=demo -y

echo "Включаю авто-инжекцию sidecar в namespace default..."
kubectl label namespace default istio-injection=enabled --overwrite

echo "Применяю Istio-манифесты..."
kubectl apply -f ../gateway.yaml
kubectl apply -f ../virtualservice.yaml
kubectl apply -f ../destinationrule.yaml

echo "Готово. Istio gateway, VirtualService и DestinationRules применены."
