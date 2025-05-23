#!/bin/bash

set -e

check_and_setup_cluster() {
    if kubectl cluster-info &>/dev/null; then
        echo "Кластер Kubernetes уже запущен и доступен."
        return 0
    fi

    echo "Кластер Kubernetes не доступен. Попытка настройки..."

    if command -v minikube &>/dev/null; then
        echo "Найден Minikube. Запускаем кластер..."
        minikube start
    elif command -v kind &>/dev/null; then
        echo "Найден Kind. Создаем кластер..."
        kind create cluster
    elif command -v docker &>/dev/null && docker info &>/dev/null; then
        echo "ВНИМАНИЕ: Docker установлен, но кластер Kubernetes не настроен."
        exit 1
    else
        echo "Установите Kubernetes."
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        echo "ОШИБКА: Не удалось подключиться к кластеру Kubernetes после настройки."
        exit 1
    fi

    echo "Кластер Kubernetes успешно настроен и готов к использованию."
}

check_and_setup_cluster

echo "Создание директории для манифестов..."
mkdir -p k8s

cat > k8s/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "INFO"
  APP_PORT: "5000"
  WELCOME_MESSAGE: "Welcome to the custom app"
  APP_PYTHON: |
    import os
    import json
    import logging
    from flask import Flask, request, jsonify


    LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO')
    APP_PORT = int(os.environ.get('APP_PORT', 5000))
    WELCOME_MESSAGE = os.environ.get('WELCOME_MESSAGE', 'Welcome to the custom app')


    log_directory = '/app/logs'
    os.makedirs(log_directory, exist_ok=True)
    log_file = os.path.join(log_directory, 'app.log')

    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL),
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler()
        ]
    )

    logger = logging.getLogger(__name__)
    app = Flask(__name__)

    @app.route('/', methods=['GET'])
    def welcome():
        logger.info("Вызвана корневая ручка")
        return WELCOME_MESSAGE

    @app.route('/status', methods=['GET'])
    def status():
        logger.info("Вызвана ручка статуса")
        return jsonify({"status": "ok"})

    @app.route('/log', methods=['POST'])
    def log_message():
        data = request.get_json()
        message = data.get('message', '')
        logger.info(f"Вызвана ручка лога с сообщением: {message}")


        with open(log_file, 'a') as f:
            f.write(f"{message}\n")

        return jsonify({"success": True})

    @app.route('/logs', methods=['GET'])
    def get_logs():
        logger.info("Вызвана ручка получения логов")
        try:
            with open(log_file, 'r') as f:
                logs = f.read()
            return logs
        except Exception as e:
            logger.error(f"Ошибка чтения логов: {e}")
            return jsonify({"error": str(e)}), 500

    if __name__ == '__main__':
        logger.info(f"Запуск приложения на порту {APP_PORT}")
        app.run(host='0.0.0.0', port=APP_PORT, debug=False)
EOF

cat > k8s/pod.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-test-pod
  labels:
    app: custom-app
spec:
  containers:
  - name: app
    image: python:3.9-slim
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -e
      pip install flask
      mkdir -p /app/logs
      echo "$(date): Starting Flask app setup..."
      cat > /app/app.py << EOF_APP
      $(cat /config/APP_PYTHON)
      EOF_APP

      echo "$(date): Flask app setup complete, starting server..."
      python /app/app.py
    ports:
    - containerPort: 5000
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
    - name: APP_PORT
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_PORT
    - name: WELCOME_MESSAGE
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: WELCOME_MESSAGE
    volumeMounts:
    - name: logs-volume
      mountPath: /app/logs
    - name: config-volume
      mountPath: /config
  volumes:
  - name: logs-volume
    emptyDir: {}
  - name: config-volume
    configMap:
      name: app-config
EOF

cat > k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: custom-app
  template:
    metadata:
      labels:
        app: custom-app
    spec:
      containers:
      - name: app
        image: python:3.9-slim
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -e
          pip install flask
          mkdir -p /app/logs
          echo "$(date): Starting Flask app setup..."
          cat > /app/app.py << EOF_APP
          $(cat /config/APP_PYTHON)
          EOF_APP

          echo "$(date): Flask app setup complete, starting server..."
          python /app/app.py
        ports:
        - containerPort: 5000
        env:
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: LOG_LEVEL
        - name: APP_PORT
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: APP_PORT
        - name: WELCOME_MESSAGE
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: WELCOME_MESSAGE
        volumeMounts:
        - name: logs-volume
          mountPath: /app/logs
        - name: config-volume
          mountPath: /config
      volumes:
      - name: logs-volume
        emptyDir: {}
      - name: config-volume
        configMap:
          name: app-config
EOF

cat > k8s/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: custom-app-service
spec:
  selector:
    app: custom-app
  ports:
  - port: 80
    targetPort: 5000
  type: ClusterIP
EOF

cat > k8s/daemonset.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
    spec:
      containers:
      - name: agent
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          while true; do
            wget -q -O - http://custom-app-service/logs || echo "Waiting for service..."
            sleep 30
          done
        volumeMounts:
        - name: node-logs
          mountPath: /host-logs
      volumes:
      - name: node-logs
        hostPath:
          path: /var/log/app-logs
          type: DirectoryOrCreate
EOF

cat > k8s/cronjob.yaml << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: log-archiver
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: archiver
            image: curlimages/curl:latest
            command: ["/bin/sh", "-c"]
            args:
            - |
              TIMESTAMP=$(date +%Y%m%d%H%M%S)
              mkdir -p /tmp/logs
              curl -s http://custom-app-service/logs > /tmp/logs/app.log
              tar -czf /tmp/app-logs-$TIMESTAMP.tar.gz -C /tmp logs
              echo "Logs archived to /tmp/app-logs-$TIMESTAMP.tar.gz"
          restartPolicy: OnFailure
EOF

echo "Применение ConfigMap..."
kubectl apply -f k8s/configmap.yaml

echo "Удаление существующего Pod (если есть)..."
kubectl delete pod app-test-pod --ignore-not-found=true

echo "Создание тестового Pod..."
kubectl apply -f k8s/pod.yaml

echo "Ожидание готовности Pod..."
kubectl wait --for=condition=Ready pod/app-test-pod --timeout=120s

echo "Проверка логов Pod для диагностики..."
kubectl logs app-test-pod

echo "Тестирование Pod (ожидаем 15 секунд для полного запуска Flask)..."
sleep 15
kubectl port-forward pod/app-test-pod 5000:5000 &
PF_PID=$!
sleep 5


echo "Тестирование API..."
echo "GET / :"
curl http://localhost:5000/
echo -e "\n\nGET /status :"
curl http://localhost:5000/status
echo -e "\n\nPOST /log :"
curl -X POST http://localhost:5000/log -H "Content-Type: application/json" -d '{"message": "Test log entry"}'
echo -e "\n\nGET /logs :"
curl http://localhost:5000/logs
echo -e "\n"


kill $PF_PID 2>/dev/null || true

echo "Удаление существующего Deployment (если есть)..."
kubectl delete deployment custom-app --ignore-not-found=true

echo "Развертывание приложения как Deployment..."
kubectl apply -f k8s/deployment.yaml

echo "Создание Service..."
kubectl apply -f k8s/service.yaml

echo "Ожидание готовности Deployment..."
kubectl wait --for=condition=Available deployment/custom-app --timeout=180s

echo "Удаление существующего DaemonSet (если есть)..."
kubectl delete daemonset log-agent --ignore-not-found=true

echo "Развертывание DaemonSet для сбора логов..."
kubectl apply -f k8s/daemonset.yaml

echo "Удаление существующего CronJob (если есть)..."
kubectl delete cronjob log-archiver --ignore-not-found=true

echo "Создание CronJob для архивации логов..."
kubectl apply -f k8s/cronjob.yaml

if ! kubectl get ns istio-system &>/dev/null; then
  echo "Установка Istio через istioctl..."
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.2 sh -
  cd istio-1.21.2
  export PATH=$PWD/bin:$PATH
  istioctl install --set profile=demo -y
  kubectl label namespace default istio-injection=enabled --overwrite
  cd ..
fi

echo "Применение Istio Gateway, VirtualService, DestinationRule..."
kubectl apply -f k8s/istio-gateway.yaml
kubectl apply -f k8s/istio-virtualservice.yaml
kubectl apply -f k8s/istio-destinationrule-app.yaml

echo "Запуск port-forward для доступа к сервису..."
kubectl port-forward svc/custom-app-service 8080:80 &
PF_SVC_PID=$!

echo "Ожидание инициализации порта (5 секунд)..."
sleep 5

echo "Проверка доступности сервиса..."
if curl -s http://localhost:8080/status > /dev/null; then
    echo "Сервис доступен. Автоматический тест:"

    echo -e "\nGET / :"
    curl http://localhost:8080/

    echo -e "\n\nGET /status :"
    curl http://localhost:8080/status

    echo -e "\n\nPOST /log :"
    curl -X POST http://localhost:8080/log -H "Content-Type: application/json" -d '{"message": "Автоматический тест успешен"}'

    echo -e "\n\nGET /logs :"
    curl http://localhost:8080/logs

    echo -e "\n\nПроверка состояния системы:"
    echo -e "\nПоды:"
    kubectl get pods

    echo -e "\nСервисы:"
    kubectl get svc
else
    echo "ОШИБКА: Сервис недоступен. Проверка состояния компонентов:"

    echo -e "\nПоды:"
    kubectl get pods

    echo -e "\nСервисы:"
    kubectl get svc

    echo -e "\nЛоги одного из подов приложения:"
    POD_NAME=$(kubectl get pods -l app=custom-app -o name | head -n 1)
    if [ -n "$POD_NAME" ]; then
        kubectl logs $POD_NAME
    fi
fi

echo "Развертывание завершено успешно!"
echo "Используйте следующую команду для доступа к сервису:"
echo "kubectl port-forward svc/custom-app-service 8080:80"
echo ""
echo "После этого можно выполнить тесты в другом терминале:"
echo "curl http://localhost:8080/"
echo "curl http://localhost:8080/status"
echo "curl -X POST http://localhost:8080/log -H \"Content-Type: application/json\" -d '{\"message\": \"Тестовое сообщение\"}'"
echo "curl http://localhost:8080/logs"


echo -e "\nPort-forward запущен и работает в фоновом режиме."
echo "Для остановки выполните: kill $PF_SVC_PID"
echo "Или нажмите Ctrl+C, если скрипт запущен в интерактивном режиме."

echo "Ожидание прерывания (нажмите Ctrl+C для остановки)..."
wait $PF_SVC_PID
