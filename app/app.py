"""
Multi-Stage Docker Pipeline Demo Application
A simple Flask application demonstrating optimized Docker builds
"""

from flask import Flask, jsonify, request
import os
import psutil
import socket
from datetime import datetime

app = Flask(__name__)

# Application metadata
APP_VERSION = os.getenv('APP_VERSION', '1.0.0')
BUILD_DATE = os.getenv('BUILD_DATE', 'unknown')
GIT_COMMIT = os.getenv('GIT_COMMIT', 'unknown')


@app.route('/')
def home():
    """Home endpoint with application info"""
    return jsonify({
        'message': 'Multi-Stage Docker Pipeline API',
        'version': APP_VERSION,
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat()
    })


@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'checks': {
            'api': 'up',
            'timestamp': datetime.utcnow().isoformat()
        }
    }), 200


@app.route('/info')
def info():
    """System information endpoint"""
    return jsonify({
        'application': {
            'version': APP_VERSION,
            'build_date': BUILD_DATE,
            'git_commit': GIT_COMMIT
        },
        'system': {
            'hostname': socket.gethostname(),
            'cpu_count': psutil.cpu_count(),
            'memory_mb': round(psutil.virtual_memory().total / (1024 * 1024), 2),
            'python_version': os.sys.version.split()[0]
        },
        'container': {
            'running_in_container': os.path.exists('/.dockerenv'),
            'user': os.getenv('USER', 'unknown')
        }
    })


@app.route('/metrics')
def metrics():
    """Resource usage metrics"""
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    
    return jsonify({
        'cpu_percent': cpu_percent,
        'memory': {
            'total_mb': round(memory.total / (1024 * 1024), 2),
            'available_mb': round(memory.available / (1024 * 1024), 2),
            'used_mb': round(memory.used / (1024 * 1024), 2),
            'percent': memory.percent
        },
        'timestamp': datetime.utcnow().isoformat()
    })


if __name__ == '__main__':
    port = int(os.getenv('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
