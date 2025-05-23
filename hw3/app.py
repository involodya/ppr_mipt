from prometheus_flask_exporter import PrometheusMetrics
import time
import os
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


metrics = PrometheusMetrics(app)

from prometheus_client import Counter, Summary

log_requests_total = Counter('app_log_requests_total', 'Total /log requests')
log_success_total = Counter('app_log_success_total', 'Successful /log')
log_fail_total = Counter('app_log_fail_total', 'Failed /log')
log_request_duration = Summary('app_log_request_duration_seconds', 'Time spent processing /log')


@app.route('/log', methods=['POST'])
@log_request_duration.time()
def log_message():
    start = time.time()
    log_requests_total.inc()
    try:
        data = request.get_json()
        message = data.get('message', '')
        logger.info(f"Вызвана ручка лога с сообщением: {message}")
        with open(log_file, 'a') as f:
            f.write(f"{message}\n")
        log_success_total.inc()
        duration = time.time() - start
        return jsonify({"success": True, "duration": duration})
    except Exception as e:
        log_fail_total.inc()
        logger.error(f"Ошибка при логировании: {e}")
        duration = time.time() - start
        return jsonify({"success": False, "error": str(e), "duration": duration}), 500


@app.route('/logs', methods=['GET'])
def get_logs():
    logger.info("Вызван ручки получения логов")
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
