#!/bin/bash

set -e

echo "==== 1. Проверяем helm ===="
if ! command -v helm &> /dev/null; then
  echo "Helm не найден. Устанавливаем..."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    brew install helm
  else
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
else
  echo "Helm уже установлен."
fi

echo "==== 2. Проверяем istioctl ===="
if ! command -v istioctl &> /dev/null; then
  echo "istioctl не найден. Устанавливаем..."
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.22.0 sh -
  export PATH="$PWD/istio-1.22.0/bin:$PATH"
  echo 'export PATH="$PWD/istio-1.22.0/bin:$PATH"' >> ~/.bashrc
else
  echo "istioctl уже установлен."
fi

echo "==== 3. Добавляем prometheus-community repo ===="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==== 4. Разворачиваем kube-prometheus-stack ===="
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

echo "==== 5. Ждем появления CRD для ServiceMonitor... ===="
for i in {1..30}; do
  if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    echo "ServiceMonitor CRD найден."
    break
  fi
  echo "Ожидание появления CRD ($i/30)..."
  sleep 5
done

echo "==== 6. Проверяем наличие необходимых YAML-файлов ===="

# Шаблон app-deployment.yaml
if [ ! -f app-deployment.yaml ]; then
cat > app-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: my-app
        image: python:3.10-slim
        command: ["sh", "-c", "pip install flask prometheus_client && python -u app.py"]
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: app-src
          mountPath: /app
        workingDir: /app
      volumes:
      - name: app-src
        hostPath:
          path: ./app
EOF
fi

# Шаблон service.yaml
if [ ! -f service.yaml ]; then
cat > service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: my-app
  labels:
    app: my-app
spec:
  ports:
    - port: 5000
      targetPort: 5000
      name: http
  selector:
    app: my-app
EOF
fi

# Шаблон servicemonitor.yaml
if [ ! -f servicemonitor.yaml ]; then
cat > servicemonitor.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - default
EOF
fi

echo "==== 7. Применяем манифесты приложения ===="
kubectl apply -f app-deployment.yaml
kubectl apply -f service.yaml

echo "==== 8. Применяем ServiceMonitor ===="
kubectl apply -f servicemonitor.yaml

echo "==== 9. Создание шаблона для Istio ServiceMonitor ===="
if [ ! -f istio-servicemonitor.yaml ]; then
cat > istio-servicemonitor.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istio
  namespace: istio-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      istio: pilot
  endpoints:
    - port: http-monitoring
      path: /metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - istio-system
EOF
fi

echo "==== 10. Готово! Проверяй Prometheus ===="
echo "Для доступа к Prometheus:"
echo "kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090"
