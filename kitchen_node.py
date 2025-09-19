# kitchen_node.py
"""
Individual Kitchen Node Implementation
Handles order processing, communication with load balancer, and health monitoring
"""

import os
import time
import json
import asyncio
import logging
import random
import threading
from datetime import datetime, timedelta
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict
from enum import Enum
from flask import Flask, request, jsonify
import redis
import requests
from prometheus_client import Counter, Histogram, Gauge, start_http_server
from concurrent.futures import ThreadPoolExecutor
import signal
import sys

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class OrderStatus(Enum):
    PENDING = "pending"
    ASSIGNED = "assigned"
    COOKING = "cooking" 
    READY = "ready"
    DELIVERED = "delivered"

@dataclass
class Order:
    id: str
    customer_id: str
    items: List[str]
    priority: int
    created_at: str
    estimated_time: int
    status: OrderStatus
    assigned_kitchen: Optional[str] = None
    started_at: Optional[str] = None
    completed_at: Optional[str] = None

class KitchenNode:
    """Individual kitchen node that processes orders"""
    
    def __init__(self):
        # Environment configuration
        self.kitchen_id = os.getenv('KITCHEN_ID', 'kitchen_1')
        self.kitchen_name = os.getenv('KITCHEN_NAME', 'Default Kitchen')
        self.kitchen_location = os.getenv('KITCHEN_LOCATION', 'Unknown')
        self.kitchen_capacity = int(os.getenv('KITCHEN_CAPACITY', '10'))
        self.specialties = os.getenv('KITCHEN_SPECIALTIES', '').split(',')
        
        # Network configuration
        self.redis_url = os.getenv('REDIS_URL', 'redis://localhost:6379')
        self.load_balancer_url = os.getenv('LOAD_BALANCER_URL', 'http://localhost:8080')
        
        # Internal state
        self.current_load = 0
        self.orders_queue = []
        self.processing_orders = {}
        self.is_running = False
        self.last_heartbeat = datetime.now()
        self.average_processing_time = random.uniform(3, 7)
        
        # Redis connection
        self.redis_client = redis.from_url(self.redis_url)
        
        # Thread pool for order processing
        self.executor = ThreadPoolExecutor(max_workers=self.kitchen_capacity)
        
        # Prometheus metrics
        self.setup_metrics()
        
        logger.info(f"Kitchen {self.kitchen_name} initialized with capacity {self.kitchen_capacity}")
    
    def setup_metrics(self):
        """Initialize Prometheus metrics"""
        self.orders_processed = Counter(
            'kitchen_orders_processed_total',
            'Total orders processed by kitchen',
            ['kitchen_id', 'status']
        )
        
        self.processing_time = Histogram(
            'kitchen_processing_time_seconds',
            'Time spent processing orders',
            ['kitchen_id']
        )
        
        self.current_load_gauge = Gauge(
            'kitchen_current_load',
            'Current load of kitchen',
            ['kitchen_id']
        )
        
        self.queue_size_gauge = Gauge(
            'kitchen_queue_size',
            'Size of kitchen order queue',
            ['kitchen_id']
        )
    
    def start(self):
        """Start kitchen operations"""
        self.is_running = True
        
        # Register with load balancer
        self.register_with_load_balancer()
        
        # Start background tasks
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()
        threading.Thread(target=self.order_processor_loop, daemon=True).start()
        
        # Start Prometheus metrics server
        start_http_server(9090)
        
        logger.info(f"Kitchen {self.kitchen_name} started successfully")
    
    def stop(self):
        """Stop kitchen operations"""
        self.is_running = False
        self.executor.shutdown(wait=True)
        logger.info(f"Kitchen {self.kitchen_name} stopped")
    
    def register_with_load_balancer(self):
        """Register this kitchen with the load balancer"""
        registration_data = {
            'kitchen_id': self.kitchen_id,
            'name': self.kitchen_name,
            'location': self.kitchen_location,
            'capacity': self.kitchen_capacity,
            'specialties': self.specialties,
            'endpoint': f'http://{self.kitchen_id}:8081'
        }
        
        try:
            response = requests.post(
                f'{self.load_balancer_url}/api/kitchens/register',
                json=registration_data,
                timeout=30
            )
            if response.status_code == 200:
                logger.info(f"Kitchen {self.kitchen_name} registered successfully")
            else:
                logger.error(f"Failed to register kitchen: {response.text}")
        except Exception as e:
            logger.error(f"Registration error: {e}")
    
    def heartbeat_loop(self):
        """Send periodic heartbeat to load balancer"""
        while self.is_running:
            try:
                heartbeat_data = {
                    'kitchen_id': self.kitchen_id,
                    'current_load': self.current_load,
                    'queue_size': len(self.orders_queue),
                    'processing_orders': len(self.processing_orders),
                    'average_processing_time': self.average_processing_time,
                    'timestamp': datetime.now().isoformat()
                }
                
                # Send to load balancer
                requests.post(
                    f'{self.load_balancer_url}/api/kitchens/heartbeat',
                    json=heartbeat_data,
                    timeout=10
                )
                
                # Update Redis
                self.redis_client.setex(
                    f'kitchen:{self.kitchen_id}:heartbeat',
                    60,  # 1 minute TTL
                    json.dumps(heartbeat_data)
                )
                
                self.last_heartbeat = datetime.now()
                
                # Update metrics
                self.current_load_gauge.labels(kitchen_id=self.kitchen_id).set(self.current_load)
                self.queue_size_gauge.labels(kitchen_id=self.kitchen_id).set(len(self.orders_queue))
                
            except Exception as e:
                logger.error(f"Heartbeat error: {e}")
            
            time.sleep(30)  # Send heartbeat every 30 seconds
    
    def order_processor_loop(self):
        """Main loop for processing orders from queue"""
        while self.is_running:
            try:
                # Check Redis for new orders assigned to this kitchen
                order_key = f'kitchen:{self.kitchen_id}:orders'
                order_data = self.redis_client.lpop(order_key)
                
                if order_data:
                    order_dict = json.loads(order_data)
                    order = Order(**order_dict)
                    self.process_order(order)
                
            except Exception as e:
                logger.error(f"Order processor error: {e}")
            
            time.sleep(1)  # Check for new orders every second
    
    def process_order(self, order: Order):
        """Process an individual order"""
        if self.current_load >= self.kitchen_capacity:
            logger.warning(f"Kitchen at capacity, queuing order {order.id}")
            self.orders_queue.append(order)
            return
        
        # Start processing
        self.current_load += 1
        self.processing_orders[order.id] = order
        order.status = OrderStatus.COOKING
        order.started_at = datetime.now().isoformat()
        
        logger.info(f"Started cooking order {order.id}: {', '.join(order.items)}")
        
        # Submit to thread pool
        future = self.executor.submit(self._cook_order, order)
        future.add_done_callback(lambda f: self._order_completed(order, f.result()))
    
    def _cook_order(self, order: Order) -> float:
        """Simulate cooking process"""
        # Calculate cooking time based on items and complexity
        base_time = len(order.items) * 2  # 2 seconds per item for demo
        complexity_factor = random.uniform(0.5, 1.5)
        cooking_time = base_time * complexity_factor
        
        # Add some randomness for realism
        cooking_time += random.uniform(-0.5, 1.0)
        cooking_time = max(1.0, cooking_time)  # Minimum 1 second
        
        # Simulate cooking
        time.sleep(cooking_time)
        
        return cooking_time
    
    def _order_completed(self, order: Order, cooking_time: float):
        """Handle order completion"""
        order.status = OrderStatus.READY
        order.completed_at = datetime.now().isoformat()
        
        # Update internal state
        self.current_load -= 1
        if order.id in self.processing_orders:
            del self.processing_orders[order.id]
        
        # Update average processing time
        self.average_processing_time = (
            self.average_processing_time * 0.9 + cooking_time * 0.1
        )
        
        # Record metrics
        self.orders_processed.labels(
            kitchen_id=self.kitchen_id, 
            status='completed'
        ).inc()
        
        self.processing_time.labels(kitchen_id=self.kitchen_id).observe(cooking_time)
        
        # Notify load balancer
        completion_data = {
            'order_id': order.id,
            'kitchen_id': self.kitchen_id,
            'processing_time': cooking_time,
            'completed_at': order.completed_at
        }
        
        try:
            requests.post(
                f'{self.load_balancer_url}/api/orders/completed',
                json=completion_data,
                timeout=10
            )
        except Exception as e:
            logger.error(f"Failed to notify completion: {e}")
        
        # Update Redis
        self.redis_client.setex(
            f'order:{order.id}:status',
            3600,  # 1 hour TTL
            json.dumps(asdict(order))
        )
        
        logger.info(f"Order {order.id} completed in {cooking_time:.2f}s")
        
        # Process next order in queue if any
        if self.orders_queue and self.current_load < self.kitchen_capacity:
            next_order = self.orders_queue.pop(0)
            self.process_order(next_order)
    
    def get_status(self) -> Dict:
        """Get current kitchen status"""
        return {
            'kitchen_id': self.kitchen_id,
            'name': self.kitchen_name,
            'location': self.kitchen_location,
            'capacity': self.kitchen_capacity,
            'current_load': self.current_load,
            'queue_size': len(self.orders_queue),
            'processing_orders': len(self.processing_orders),
            'specialties': self.specialties,
            'average_processing_time': self.average_processing_time,
            'last_heartbeat': self.last_heartbeat.isoformat(),
            'uptime': str(datetime.now() - self.last_heartbeat)
        }

# Flask API for kitchen node
app = Flask(__name__)
kitchen_node = KitchenNode()

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'kitchen_id': kitchen_node.kitchen_id,
        'uptime': str(datetime.now() - kitchen_node.last_heartbeat)
    })

@app.route('/status', methods=['GET'])
def get_status():
    """Get kitchen status"""
    return jsonify(kitchen_node.get_status())

@app.route('/orders', methods=['POST'])
def receive_order():
    """Receive new order from load balancer"""
    data = request.get_json()
    
    try:
        order = Order(**data)
        kitchen_node.process_order(order)
        
        return jsonify({
            'status': 'accepted',
            'order_id': order.id,
            'estimated_completion': datetime.now() + timedelta(
                seconds=kitchen_node.average_processing_time
            )
        })
        
    except Exception as e:
        logger.error(f"Failed to process order: {e}")
        return jsonify({'error': str(e)}), 400

@app.route('/orders/<order_id>/status', methods=['GET'])
def get_order_status(order_id):
    """Get status of specific order"""
    if order_id in kitchen_node.processing_orders:
        order = kitchen_node.processing_orders[order_id]
        return jsonify(asdict(order))
    
    # Check completed orders in Redis
    try:
        order_data = kitchen_node.redis_client.get(f'order:{order_id}:status')
        if order_data:
            return jsonify(json.loads(order_data))
    except Exception as e:
        logger.error(f"Failed to get order status: {e}")
    
    return jsonify({'error': 'Order not found'}), 404

@app.route('/metrics', methods=['GET'])
def get_metrics():
    """Get kitchen metrics"""
    return jsonify({
        'kitchen_id': kitchen_node.kitchen_id,
        'orders_processed': kitchen_node.orders_processed._value._value,
        'average_processing_time': kitchen_node.average_processing_time,
        'current_load': kitchen_node.current_load,
        'queue_size': len(kitchen_node.orders_queue),
        'capacity_utilization': kitchen_node.current_load / kitchen_node.kitchen_capacity
    })

def signal_handler(sig, frame):
    """Handle shutdown signals"""
    logger.info("Shutdown signal received, stopping kitchen...")
    kitchen_node.stop()
    sys.exit(0)

if __name__ == '__main__':
    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Start kitchen node
    kitchen_node.start()
    
    # Start Flask app
    logger.info(f"Kitchen {kitchen_node.kitchen_name} API starting on port 8081")
    app.run(host='0.0.0.0', port=8081, debug=False)