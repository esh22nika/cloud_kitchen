import json
import time
import random
from datetime import datetime
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

@app.route('/health')
def health():
    return jsonify({'status': 'healthy', 'timestamp': datetime.now().isoformat()})

@app.route('/api/status')
def status():
    kitchens = {
        'kitchen_1': {'name': 'Downtown Kitchen', 'load': random.randint(20, 80), 'capacity': 10, 'status': 'available', 'queue_size': random.randint(0, 5)},
        'kitchen_2': {'name': 'Uptown Bistro', 'load': random.randint(20, 80), 'capacity': 12, 'status': 'available', 'queue_size': random.randint(0, 5)},
        'kitchen_3': {'name': 'Suburb Deli', 'load': random.randint(20, 80), 'capacity': 8, 'status': 'available', 'queue_size': random.randint(0, 5)},
        'kitchen_4': {'name': 'Express Kitchen', 'load': random.randint(20, 80), 'capacity': 15, 'status': 'available', 'queue_size': random.randint(0, 5)}
    }
    return jsonify({
        'kitchens': kitchens,
        'system_health': 'Healthy',
        'total_orders': random.randint(100, 500),
        'uptime': '99.9%'
    })

@app.route('/api/orders', methods=['POST'])
def create_order():
    order_id = f'order_{random.randint(1000, 9999)}'
    return jsonify({'order_id': order_id, 'status': 'created'})

@app.route('/api/migrate', methods=['POST'])
def migrate_orders():
    return jsonify({'migrations': random.randint(1, 3), 'status': 'completed'})

@app.route('/api/simulate_rush', methods=['POST'])
def simulate_rush():
    orders = [f'order_{random.randint(1000, 9999)}' for _ in range(10)]
    return jsonify({'rush_orders': orders, 'count': len(orders)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)