# distributed_chef_backend.py
"""
Distributed Chef Challenge - Backend Implementation
Complete microservices architecture with load balancing, task scheduling, and process migration
"""

import asyncio
import json
import time
import random
import uuid
from datetime import datetime
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict
from enum import Enum
import logging
from flask import Flask, request, jsonify
from flask_socketio import SocketIO, emit
import redis
import threading
from queue import Queue, Empty
import requests

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class OrderStatus(Enum):
    PENDING = "pending"
    ASSIGNED = "assigned" 
    COOKING = "cooking"
    READY = "ready"
    DELIVERED = "delivered"
    CANCELLED = "cancelled"

class KitchenStatus(Enum):
    AVAILABLE = "available"
    BUSY = "busy"
    OVERLOADED = "overloaded"
    MAINTENANCE = "maintenance"

@dataclass
class Order:
    id: str
    customer_id: str
    items: List[str]
    priority: int
    created_at: datetime
    estimated_time: int  # in minutes
    status: OrderStatus
    assigned_kitchen: Optional[str] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

@dataclass 
class Kitchen:
    id: str
    name: str
    location: str
    capacity: int
    current_load: int
    status: KitchenStatus
    specialties: List[str]
    orders_queue: List[str]
    average_processing_time: float
    last_heartbeat: datetime

class LoadBalancer:
    """Advanced load balancer with multiple scheduling algorithms"""
    
    def __init__(self):
        self.kitchens: Dict[str, Kitchen] = {}
        self.orders: Dict[str, Order] = {}
        self.redis_client = redis.Redis(host='localhost', port=6379, db=0)
        
    def register_kitchen(self, kitchen: Kitchen):
        """Register a new kitchen node"""
        self.kitchens[kitchen.id] = kitchen
        logger.info(f"Kitchen {kitchen.name} registered with capacity {kitchen.capacity}")
    
    def get_optimal_kitchen(self, order: Order) -> Optional[str]:
        """Select optimal kitchen using weighted scoring algorithm"""
        available_kitchens = [k for k in self.kitchens.values() 
                            if k.status == KitchenStatus.AVAILABLE]
        
        if not available_kitchens:
            return None
            
        # Calculate scores based on multiple factors
        scored_kitchens = []
        for kitchen in available_kitchens:
            score = self._calculate_kitchen_score(kitchen, order)
            scored_kitchens.append((kitchen.id, score))
        
        # Sort by score (higher is better)
        scored_kitchens.sort(key=lambda x: x[1], reverse=True)
        return scored_kitchens[0][0] if scored_kitchens else None
    
    def _calculate_kitchen_score(self, kitchen: Kitchen, order: Order) -> float:
        """Calculate kitchen suitability score"""
        # Load factor (lower load = higher score)
        load_score = (kitchen.capacity - kitchen.current_load) / kitchen.capacity
        
        # Specialty match
        specialty_score = 0.0
        for item in order.items:
            if any(specialty in item.lower() for specialty in kitchen.specialties):
                specialty_score += 1
        specialty_score = specialty_score / len(order.items) if order.items else 0
        
        # Processing time factor
        time_score = 1.0 / (kitchen.average_processing_time + 1)
        
        # Distance factor (simplified - in real implementation would use actual coordinates)
        distance_score = 0.5  # Placeholder
        
        # Weighted combination
        total_score = (
            load_score * 0.4 +
            specialty_score * 0.3 + 
            time_score * 0.2 +
            distance_score * 0.1
        )
        
        return total_score
    
    def assign_order(self, order: Order) -> bool:
        """Assign order to optimal kitchen"""
        kitchen_id = self.get_optimal_kitchen(order)
        
        if not kitchen_id:
            logger.warning(f"No available kitchen for order {order.id}")
            return False
            
        kitchen = self.kitchens[kitchen_id]
        kitchen.orders_queue.append(order.id)
        kitchen.current_load += 1
        
        order.assigned_kitchen = kitchen_id
        order.status = OrderStatus.ASSIGNED
        
        # Update kitchen status based on load
        if kitchen.current_load >= kitchen.capacity * 0.9:
            kitchen.status = KitchenStatus.OVERLOADED
        elif kitchen.current_load >= kitchen.capacity * 0.7:
            kitchen.status = KitchenStatus.BUSY
            
        logger.info(f"Order {order.id} assigned to kitchen {kitchen.name}")
        return True
    
    def migrate_orders(self):
        """Migrate orders from overloaded kitchens"""
        overloaded = [k for k in self.kitchens.values() 
                     if k.status == KitchenStatus.OVERLOADED]
        available = [k for k in self.kitchens.values() 
                    if k.status == KitchenStatus.AVAILABLE and k.current_load < k.capacity * 0.5]
        
        migrations = 0
        for overloaded_kitchen in overloaded:
            if not overloaded_kitchen.orders_queue or not available:
                continue
                
            # Find orders that can be migrated (not yet cooking)
            migratable_orders = []
            for order_id in overloaded_kitchen.orders_queue:
                order = self.orders.get(order_id)
                if order and order.status in [OrderStatus.PENDING, OrderStatus.ASSIGNED]:
                    migratable_orders.append(order)
            
            # Migrate up to 2 orders
            for order in migratable_orders[:2]:
                target_kitchen = min(available, key=lambda k: k.current_load)
                
                # Remove from overloaded kitchen
                overloaded_kitchen.orders_queue.remove(order.id)
                overloaded_kitchen.current_load -= 1
                
                # Add to target kitchen
                target_kitchen.orders_queue.append(order.id)
                target_kitchen.current_load += 1
                
                order.assigned_kitchen = target_kitchen.id
                migrations += 1
                
                logger.info(f"Order {order.id} migrated from {overloaded_kitchen.name} to {target_kitchen.name}")
                
                # Update kitchen statuses
                if target_kitchen.current_load >= target_kitchen.capacity * 0.7:
                    target_kitchen.status = KitchenStatus.BUSY
                    
        return migrations

class KitchenNode:
    """Individual kitchen node that processes orders"""
    
    def __init__(self, kitchen: Kitchen):
        self.kitchen = kitchen
        self.processing_queue = Queue()
        self.is_running = False
        self.worker_thread = None
        
    def start(self):
        """Start kitchen processing"""
        self.is_running = True
        self.worker_thread = threading.Thread(target=self._process_orders)
        self.worker_thread.start()
        logger.info(f"Kitchen {self.kitchen.name} started processing")
    
    def stop(self):
        """Stop kitchen processing"""
        self.is_running = False
        if self.worker_thread:
            self.worker_thread.join()
            
    def add_order(self, order: Order):
        """Add order to processing queue"""
        self.processing_queue.put(order)
        
    def _process_orders(self):
        """Main order processing loop"""
        while self.is_running:
            try:
                order = self.processing_queue.get(timeout=1)
                self._cook_order(order)
            except Empty:
                continue
                
    def _cook_order(self, order: Order):
        """Simulate cooking process"""
        order.status = OrderStatus.COOKING
        order.started_at = datetime.now()
        
        logger.info(f"Kitchen {self.kitchen.name} started cooking order {order.id}")
        
        # Simulate cooking time
        cooking_time = random.uniform(2, 8)  # 2-8 seconds for demo
        time.sleep(cooking_time)
        
        order.status = OrderStatus.READY
        order.completed_at = datetime.now()
        
        # Update kitchen load
        self.kitchen.current_load = max(0, self.kitchen.current_load - 1)
        if order.id in self.kitchen.orders_queue:
            self.kitchen.orders_queue.remove(order.id)
            
        logger.info(f"Order {order.id} ready from kitchen {self.kitchen.name}")

class DistributedChefSystem:
    """Main system orchestrator"""
    
    def __init__(self):
        self.load_balancer = LoadBalancer()
        self.kitchen_nodes: Dict[str, KitchenNode] = {}
        self.order_counter = 1
        self.stats = {
            'total_orders': 0,
            'completed_orders': 0,
            'average_processing_time': 0.0,
            'system_uptime': datetime.now()
        }
        
    def initialize_kitchens(self):
        """Initialize kitchen nodes"""
        kitchens_config = [
            {
                'id': 'kitchen_1',
                'name': 'Downtown Kitchen',
                'location': 'Downtown',
                'capacity': 10,
                'specialties': ['pizza', 'pasta', 'burger']
            },
            {
                'id': 'kitchen_2', 
                'name': 'Uptown Bistro',
                'location': 'Uptown',
                'capacity': 12,
                'specialties': ['salad', 'soup', 'sandwich']
            },
            {
                'id': 'kitchen_3',
                'name': 'Suburb Deli',
                'location': 'Suburbs', 
                'capacity': 8,
                'specialties': ['wrap', 'smoothie', 'breakfast']
            },
            {
                'id': 'kitchen_4',
                'name': 'Express Kitchen',
                'location': 'Mall',
                'capacity': 15,
                'specialties': ['fast food', 'snacks', 'drinks']
            }
        ]
        
        for config in kitchens_config:
            kitchen = Kitchen(
                id=config['id'],
                name=config['name'],
                location=config['location'],
                capacity=config['capacity'],
                current_load=0,
                status=KitchenStatus.AVAILABLE,
                specialties=config['specialties'],
                orders_queue=[],
                average_processing_time=random.uniform(3, 7),
                last_heartbeat=datetime.now()
            )
            
            self.load_balancer.register_kitchen(kitchen)
            kitchen_node = KitchenNode(kitchen)
            self.kitchen_nodes[kitchen.id] = kitchen_node
            kitchen_node.start()
    
    def create_order(self, customer_id: str, items: List[str], priority: int = 1) -> str:
        """Create a new order"""
        order_id = f"order_{self.order_counter:04d}"
        self.order_counter += 1
        
        order = Order(
            id=order_id,
            customer_id=customer_id,
            items=items,
            priority=priority,
            created_at=datetime.now(),
            estimated_time=len(items) * 5,  # 5 minutes per item
            status=OrderStatus.PENDING
        )
        
        self.load_balancer.orders[order_id] = order
        
        # Try to assign order immediately
        if self.load_balancer.assign_order(order):
            # Send to kitchen node for processing
            kitchen_node = self.kitchen_nodes[order.assigned_kitchen]
            kitchen_node.add_order(order)
        
        self.stats['total_orders'] += 1
        return order_id
    
    def get_system_status(self) -> Dict:
        """Get current system status"""
        kitchen_status = {}
        for kitchen_id, kitchen in self.load_balancer.kitchens.items():
            kitchen_status[kitchen_id] = {
                'name': kitchen.name,
                'location': kitchen.location,
                'load': kitchen.current_load,
                'capacity': kitchen.capacity,
                'status': kitchen.status.value,
                'queue_size': len(kitchen.orders_queue),
                'avg_processing_time': kitchen.average_processing_time
            }
        
        return {
            'kitchens': kitchen_status,
            'stats': self.stats,
            'total_orders': len(self.load_balancer.orders),
            'system_health': self._calculate_system_health()
        }
    
    def _calculate_system_health(self) -> str:
        """Calculate overall system health"""
        total_capacity = sum(k.capacity for k in self.load_balancer.kitchens.values())
        total_load = sum(k.current_load for k in self.load_balancer.kitchens.values())
        
        utilization = total_load / total_capacity if total_capacity > 0 else 0
        
        if utilization < 0.5:
            return "Healthy"
        elif utilization < 0.8:
            return "Busy"
        else:
            return "Overloaded"

# Flask API for external integration
app = Flask(__name__)
app.config['SECRET_KEY'] = 'distributed_chef_secret'
socketio = SocketIO(app, cors_allowed_origins="*")

# Global system instance
chef_system = DistributedChefSystem()

@app.route('/api/orders', methods=['POST'])
def create_order():
    """API endpoint to create new order"""
    data = request.get_json()
    
    order_id = chef_system.create_order(
        customer_id=data.get('customer_id', f'customer_{random.randint(1000, 9999)}'),
        items=data.get('items', ['Random Item']),
        priority=data.get('priority', 1)
    )
    
    # Emit real-time update
    socketio.emit('order_created', {
        'order_id': order_id,
        'system_status': chef_system.get_system_status()
    })
    
    return jsonify({'order_id': order_id, 'status': 'created'})

@app.route('/api/status', methods=['GET'])
def get_status():
    """Get system status"""
    return jsonify(chef_system.get_system_status())

@app.route('/api/migrate', methods=['POST'])
def migrate_orders():
    """Trigger order migration"""
    migrations = chef_system.load_balancer.migrate_orders()
    
    socketio.emit('orders_migrated', {
        'migrations': migrations,
        'system_status': chef_system.get_system_status()
    })
    
    return jsonify({'migrations': migrations, 'status': 'completed'})

@app.route('/api/simulate_rush', methods=['POST'])
def simulate_rush():
    """Simulate order rush"""
    rush_orders = []
    food_items = [
        'Pizza Margherita', 'Beef Burger', 'Chicken Sandwich',
        'Caesar Salad', 'Pasta Carbonara', 'Fish Tacos',
        'Vegetable Soup', 'Chocolate Cake', 'Ice Cream'
    ]
    
    for i in range(10):
        items = random.sample(food_items, random.randint(1, 3))
        order_id = chef_system.create_order(
            customer_id=f'rush_customer_{i}',
            items=items,
            priority=2
        )
        rush_orders.append(order_id)
    
    socketio.emit('rush_simulated', {
        'orders': rush_orders,
        'system_status': chef_system.get_system_status()
    })
    
    return jsonify({'rush_orders': rush_orders, 'count': len(rush_orders)})

# WebSocket events for real-time updates
@socketio.on('connect')
def handle_connect():
    emit('system_status', chef_system.get_system_status())

@socketio.on('request_status')
def handle_status_request():
    emit('system_status', chef_system.get_system_status())

# Background task for system monitoring
def system_monitor():
    """Background monitoring task"""
    while True:
        time.sleep(5)  # Check every 5 seconds
        
        # Update kitchen heartbeats
        for kitchen in chef_system.load_balancer.kitchens.values():
            kitchen.last_heartbeat = datetime.now()
        
        # Check for overloaded kitchens and trigger migration
        overloaded_count = sum(1 for k in chef_system.load_balancer.kitchens.values() 
                              if k.status == KitchenStatus.OVERLOADED)
        
        if overloaded_count > 0:
            migrations = chef_system.load_balancer.migrate_orders()
            if migrations > 0:
                socketio.emit('auto_migration', {
                    'migrations': migrations,
                    'reason': 'Overload detected'
                })
        
        # Emit periodic status updates
        socketio.emit('system_heartbeat', chef_system.get_system_status())

if __name__ == '__main__':
    # Initialize system
    chef_system.initialize_kitchens()
    
    # Start background monitoring
    monitor_thread = threading.Thread(target=system_monitor)
    monitor_thread.daemon = True
    monitor_thread.start()
    
    # Start Flask-SocketIO server
    print("🍳 Distributed Chef System Starting...")
    print("🏪 Kitchens initialized")
    print("⚖️ Load balancer active")
    print("🌐 API server running on http://localhost:5000")
    
    socketio.run(app, host='0.0.0.0', port=5000, debug=True)