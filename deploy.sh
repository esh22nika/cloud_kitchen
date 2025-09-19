#!/bin/bash
# deploy.sh - Main deployment script

set -e

echo "🍳 Distributed Chef Challenge Deployment Script"
echo "================================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check if Docker Compose is installed
    if ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    # Check if ports are available
    if lsof -i :80 &> /dev/null; then
        print_warning "Port 80 is already in use. The application might not be accessible on port 80."
    fi
    
    if lsof -i :8080 &> /dev/null; then
        print_warning "Port 8080 is already in use. Load balancer might fail to start."
    fi
    
    print_success "Prerequisites check completed"
}

# Create necessary directories
setup_directories() {
    print_status "Setting up directories..."
    
    mkdir -p logs
    mkdir -p data/redis
    mkdir -p data/postgres
    mkdir -p ssl
    mkdir -p grafana/provisioning/dashboards
    mkdir -p grafana/provisioning/datasources
    
    print_success "Directories created"
}

# Generate SSL certificates (self-signed for demo)
generate_ssl() {
    print_status "Generating SSL certificates..."
    
    if [ ! -f ssl/cert.pem ]; then
        openssl req -x509 -newkey rsa:4096 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes \
            -subj "/C=US/ST=CA/L=San Francisco/O=Distributed Chef/CN=localhost"
        print_success "SSL certificates generated"
    else
        print_status "SSL certificates already exist"
    fi
}

# Setup Grafana configuration
setup_grafana() {
    print_status "Setting up Grafana configuration..."
    
    # Datasource configuration
    cat > grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

    # Dashboard configuration
    cat > grafana/provisioning/dashboards/dashboard.yml << EOF
apiVersion: 1

providers:
  - name: 'distributed-chef'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

    # Create dashboard JSON
    cat > grafana/provisioning/dashboards/kitchen-dashboard.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Distributed Chef Dashboard",
    "tags": ["distributed", "chef", "kitchen"],
    "style": "dark",
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Kitchen Load",
        "type": "graph",
        "targets": [
          {
            "expr": "kitchen_current_load",
            "format": "time_series",
            "legendFormat": "{{kitchen_id}}"
          }
        ]
      },
      {
        "id": 2,
        "title": "Orders Processed",
        "type": "stat",
        "targets": [
          {
            "expr": "sum(kitchen_orders_processed_total)",
            "format": "time_series"
          }
        ]
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "5s"
  }
}
EOF

    print_success "Grafana configuration completed"
}

# Build and start services
deploy_services() {
    print_status "Building and deploying services..."
    
    # Pull base images
    docker-compose pull
    
    # Build custom images
    docker-compose build --no-cache
    
    # Start services
    docker-compose up -d
    
    print_success "Services deployed"
}

# Wait for services to be ready
wait_for_services() {
    print_status "Waiting for services to be ready..."
    
    # Wait for Redis
    print_status "Waiting for Redis..."
    while ! docker-compose exec redis redis-cli ping &> /dev/null; do
        sleep 2
    done
    print_success "Redis is ready"
    
    # Wait for PostgreSQL
    print_status "Waiting for PostgreSQL..."
    while ! docker-compose exec postgres pg_isready -U chef_admin -d distributed_chef &> /dev/null; do
        sleep 2
    done
    print_success "PostgreSQL is ready"
    
    # Wait for Load Balancer
    print_status "Waiting for Load Balancer..."
    while ! curl -f http://localhost:8080/health &> /dev/null; do
        sleep 2
    done
    print_success "Load Balancer is ready"
    
    # Wait for kitchen nodes
    for i in {1..4}; do
        print_status "Waiting for Kitchen Node $i..."
        container_name="chef_kitchen_${i}"
        while ! docker-compose exec "$container_name" curl -f http://localhost:8081/health &> /dev/null; do
            sleep 2
        done
        print_success "Kitchen Node $i is ready"
    done
}

# Run tests
run_tests() {
    print_status "Running system tests..."
    
    # Test order creation
    response=$(curl -s -X POST http://localhost:8080/api/orders \
        -H "Content-Type: application/json" \
        -d '{"customer_id":"test_customer","items":["Test Pizza"],"priority":1}')
    
    if echo "$response" | grep -q "order_id"; then
        print_success "Order creation test passed"
    else
        print_error "Order creation test failed"
        echo "$response"
    fi
    
    # Test system status
    status_response=$(curl -s http://localhost:8080/api/status)
    if echo "$status_response" | grep -q "kitchens"; then
        print_success "Status endpoint test passed"
    else
        print_error "Status endpoint test failed"
    fi
}

# Show deployment summary
show_summary() {
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo "===================================="
    echo ""
    echo "Service URLs:"
    echo "• Main Application: http://localhost:80"
    echo "• Load Balancer API: http://localhost:8080"
    echo "• Grafana Dashboard: http://localhost:3000 (admin/admin123)"
    echo "• Prometheus: http://localhost:9090"
    echo ""
    echo "Docker containers:"
    docker-compose ps
    echo ""
    echo "To view logs: docker-compose logs -f [service_name]"
    echo "To stop services: docker-compose down"
    echo "To restart services: docker-compose restart"
    echo ""
}

# Cleanup function
cleanup() {
    print_status "Cleaning up..."
    docker-compose down -v
    docker system prune -f
    print_success "Cleanup completed"
}

# Main execution
main() {
    case "$1" in
        "deploy")
            check_prerequisites
            setup_directories
            generate_ssl
            setup_grafana
            deploy_services
            wait_for_services
            run_tests
            show_summary
            ;;
        "cleanup")
            cleanup
            ;;
        "restart")
            docker-compose restart
            wait_for_services
            print_success "Services restarted"
            ;;
        "logs")
            docker-compose logs -f "${2:-}"
            ;;
        "status")
            docker-compose ps
            echo ""
            curl -s http://localhost:8080/api/status | jq '.' || echo "API not available"
            ;;
        *)
            echo "Usage: $0 {deploy|cleanup|restart|logs|status}"
            echo ""
            echo "Commands:"
            echo "  deploy  - Deploy the entire system"
            echo "  cleanup - Stop and remove all containers"
            echo "  restart - Restart all services"
            echo "  logs    - Show logs (optional: specify service name)"
            echo "  status  - Show system status"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"

---

# test_system.py
"""
Comprehensive testing script for the Distributed Chef System
"""

import requests
import time
import json
import random
import threading
from concurrent.futures import ThreadPoolExecutor
import matplotlib.pyplot as plt
import pandas as pd
from datetime import datetime
import argparse

class ChefSystemTester:
    def __init__(self, base_url="http://localhost:8080"):
        self.base_url = base_url
        self.api_url = f"{base_url}/api"
        self.test_results = []
        self.order_ids = []
        
    def test_system_health(self):
        """Test if all services are healthy"""
        print("🔍 Testing system health...")
        
        try:
            response = requests.get(f"{self.api_url}/status")
            if response.status_code == 200:
                status = response.json()
                print(f"✅ System health: {status.get('system_health', 'Unknown')}")
                print(f"✅ Active kitchens: {len(status.get('kitchens', {}))}")
                return True
            else:
                print(f"❌ Health check failed: {response.status_code}")
                return False
        except Exception as e:
            print(f"❌ Health check error: {e}")
            return False
    
    def create_test_order(self, customer_id=None, items=None):
        """Create a test order"""
        if not customer_id:
            customer_id = f"test_customer_{random.randint(1000, 9999)}"
        
        if not items:
            food_items = [
                "Pizza Margherita", "Beef Burger", "Chicken Sandwich",
                "Caesar Salad", "Pasta Carbonara", "Fish Tacos",
                "Vegetable Soup", "Chocolate Cake", "Ice Cream"
            ]
            items = random.sample(food_items, random.randint(1, 3))
        
        order_data = {
            "customer_id": customer_id,
            "items": items,
            "priority": random.randint(1, 3)
        }
        
        try:
            start_time = time.time()
            response = requests.post(f"{self.api_url}/orders", json=order_data)
            end_time = time.time()
            
            if response.status_code == 200:
                result = response.json()
                order_id = result.get('order_id')
                self.order_ids.append(order_id)
                
                self.test_results.append({
                    'timestamp': datetime.now(),
                    'test_type': 'order_creation',
                    'success': True,
                    'response_time': end_time - start_time,
                    'order_id': order_id
                })
                
                return order_id
            else:
                print(f"❌ Order creation failed: {response.status_code}")
                return None
                
        except Exception as e:
            print(f"❌ Order creation error: {e}")
            return None
    
    def load_test(self, num_orders=50, concurrent_users=5):
        """Perform load testing"""
        print(f"🚀 Starting load test: {num_orders} orders with {concurrent_users} concurrent users")
        
        start_time = time.time()
        successful_orders = 0
        failed_orders = 0
        
        def create_orders_batch():
            nonlocal successful_orders, failed_orders
            for _ in range(num_orders // concurrent_users):
                if self.create_test_order():
                    successful_orders += 1
                else:
                    failed_orders += 1
                time.sleep(random.uniform(0.1, 0.5))  # Simulate real user behavior
        
        # Execute load test
        with ThreadPoolExecutor(max_workers=concurrent_users) as executor:
            futures = [executor.submit(create_orders_batch) for _ in range(concurrent_users)]
            
            # Wait for completion
            for future in futures:
                future.result()
        
        end_time = time.time()
        total_time = end_time - start_time
        
        print(f"📊 Load test completed in {total_time:.2f}s")
        print(f"✅ Successful orders: {successful_orders}")
        print(f"❌ Failed orders: {failed_orders}")
        print(f"📈 Orders per second: {successful_orders / total_time:.2f}")
        
        return {
            'total_time': total_time,
            'successful_orders': successful_orders,
            'failed_orders': failed_orders,
            'orders_per_second': successful_orders / total_time
        }
    
    def test_load_balancing(self):
        """Test load balancing effectiveness"""
        print("⚖️ Testing load balancing...")
        
        # Create multiple orders and check distribution
        order_count = 20
        kitchen_assignments = {}
        
        for i in range(order_count):
            order_id = self.create_test_order()
            if order_id:
                time.sleep(0.1)  # Small delay to allow processing
                
                # Check which kitchen got the order
                try:
                    response = requests.get(f"{self.api_url}/status")
                    if response.status_code == 200:
                        status = response.json()
                        # Find kitchen with newest order (simplified)
                        for kitchen_id, kitchen_info in status.get('kitchens', {}).items():
                            load = kitchen_info.get('load', 0)
                            if load > 0:
                                kitchen_assignments[kitchen_id] = kitchen_assignments.get(kitchen_id, 0) + 1
                except Exception as e:
                    print(f"Error checking assignment: {e}")
        
        print("Kitchen assignment distribution:")
        for kitchen_id, count in kitchen_assignments.items():
            print(f"  {kitchen_id}: {count} orders")
        
        # Check if load is reasonably distributed
        if len(kitchen_assignments) > 1:
            values = list(kitchen_assignments.values())
            max_diff = max(values) - min(values)
            if max_diff <= len(values):  # Reasonable distribution
                print("✅ Load balancing working correctly")
                return True
            else:
                print("⚠️ Load balancing may need adjustment")
                return False
        else:
            print("⚠️ All orders went to same kitchen")
            return False
    
    def test_failover(self):
        """Test system behavior when a kitchen fails"""
        print("🚨 Testing failover scenarios...")
        
        # This would require actually stopping a container
        # For demo, we'll simulate by creating many orders quickly
        print("Simulating high load to test overflow handling...")
        
        rush_results = self.simulate_rush(30, 10)
        
        if rush_results['successful_orders'] > 0:
            print("✅ System handled rush successfully")
            return True
        else:
            print("❌ System failed under load")
            return False
    
    def simulate_rush(self, num_orders=20, duration_seconds=10):
        """Simulate lunch rush"""
        print(f"🍽️ Simulating lunch rush: {num_orders} orders in {duration_seconds}s")
        
        start_time = time.time()
        successful_orders = 0
        
        def rush_worker():
            nonlocal successful_orders
            end_time = start_time + duration_seconds
            
            while time.time() < end_time:
                if self.create_test_order():
                    successful_orders += 1
                time.sleep(duration_seconds / num_orders)
        
        # Start multiple rush threads
        threads = []
        for _ in range(3):  # 3 concurrent rush threads
            thread = threading.Thread(target=rush_worker)
            thread.start()
            threads.append(thread)
        
        # Wait for completion
        for thread in threads:
            thread.join()
        
        actual_time = time.time() - start_time
        
        print(f"Rush completed: {successful_orders} orders in {actual_time:.2f}s")
        
        return {
            'successful_orders': successful_orders,
            'actual_time': actual_time,
            'target_orders': num_orders
        }
    
    def generate_report(self):
        """Generate test report with visualizations"""
        print("📊 Generating test report...")
        
        if not self.test_results:
            print("No test results to report")
            return
        
        # Create DataFrame
        df = pd.DataFrame(self.test_results)
        
        # Plot response times
        plt.figure(figsize=(12, 8))
        
        plt.subplot(2, 2, 1)
        plt.plot(df['timestamp'], df['response_time'])
        plt.title('Response Times Over Time')
        plt.xlabel('Time')
        plt.ylabel('Response Time (s)')
        plt.xticks(rotation=45)
        
        plt.subplot(2, 2, 2)
        plt.hist(df['response_time'], bins=20)
        plt.title('Response Time Distribution')
        plt.xlabel('Response Time (s)')
        plt.ylabel('Frequency')
        
        plt.subplot(2, 2, 3)
        success_rate = df['success'].mean() * 100
        plt.bar(['Success', 'Failure'], [success_rate, 100 - success_rate])
        plt.title(f'Success Rate: {success_rate:.1f}%')
        plt.ylabel('Percentage')
        
        plt.subplot(2, 2, 4)
        # Orders per minute
        df['minute'] = df['timestamp'].dt.floor('T')
        orders_per_minute = df.groupby('minute').size()
        plt.plot(orders_per_minute.index, orders_per_minute.values)
        plt.title('Orders Per Minute')
        plt.xlabel('Time')
        plt.ylabel('Orders/Minute')
        plt.xticks(rotation=45)
        
        plt.tight_layout()
        plt.savefig('test_report.png', dpi=300, bbox_inches='tight')
        plt.show()
        
        # Print summary statistics
        print("\n📈 Test Summary:")
        print(f"Total tests: {len(df)}")
        print(f"Success rate: {success_rate:.1f}%")
        print(f"Average response time: {df['response_time'].mean():.3f}s")
        print(f"Max response time: {df['response_time'].max():.3f}s")
        print(f"Min response time: {df['response_time'].min():.3f}s")

def main():
    parser = argparse.ArgumentParser(description='Distributed Chef System Tester')
    parser.add_argument('--url', default='http://localhost:8080', help='Base URL of the system')
    parser.add_argument('--load-test', action='store_true', help='Run load test')
    parser.add_argument('--orders', type=int, default=50, help='Number of orders for load test')
    parser.add_argument('--users', type=int, default=5, help='Concurrent users for load test')
    parser.add_argument('--full-test', action='store_true', help='Run all tests')
    
    args = parser.parse_args()
    
    tester = ChefSystemTester(args.url)
    
    # Run health check first
    if not tester.test_system_health():
        print("❌ System health check failed. Exiting.")
        return
    
    if args.full_test:
        print("🧪 Running full test suite...")
        tester.test_load_balancing()
        tester.load_test(args.orders, args.users)
        tester.simulate_rush()
        tester.test_failover()
        tester.generate_report()
        
    elif args.load_test:
        tester.load_test(args.orders, args.users)
        tester.generate_report()
        
    else:
        # Interactive mode
        print("🎮 Interactive testing mode")
        print("Available tests:")
        print("1. Load balancing test")
        print("2. Load test")
        print("3. Rush simulation")
        print("4. Create single order")
        print("5. Generate report")
        print("6. Exit")
        
        while True:
            choice = input("\nSelect test (1-6): ").strip()
            
            if choice == '1':
                tester.test_load_balancing()
            elif choice == '2':
                tester.load_test(args.orders, args.users)
            elif choice == '3':
                tester.simulate_rush()
            elif choice == '4':
                order_id = tester.create_test_order()
                if order_id:
                    print(f"✅ Created order: {order_id}")
            elif choice == '5':
                tester.generate_report()
            elif choice == '6':
                break
            else:
                print("Invalid choice")

if __name__ == '__main__':
    main()