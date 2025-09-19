# deploy.ps1 - Windows PowerShell deployment script

param(
    [string]$Action = "deploy"
)

# Colors for output
$Red = "Red"
$Green = "Green" 
$Yellow = "Yellow"
$Blue = "Cyan"

function Write-Status {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor $Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor $Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor $Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor $Red
}

function Test-Prerequisites {
    Write-Status "Checking prerequisites..."
    
    # Check Docker
    try {
        $dockerVersion = docker --version
        Write-Success "Docker found: $dockerVersion"
    } catch {
        Write-Error-Custom "Docker is not installed or not in PATH. Please install Docker Desktop for Windows."
        return $false
    }
    
    # Check Docker Compose
    try {
        $composeVersion = docker-compose --version
        Write-Success "Docker Compose found: $composeVersion"
    } catch {
        Write-Error-Custom "Docker Compose is not installed or not in PATH."
        return $false
    }
    
    # Check if Docker is running
    try {
        docker ps | Out-Null
        Write-Success "Docker daemon is running"
    } catch {
        Write-Error-Custom "Docker daemon is not running. Please start Docker Desktop."
        return $false
    }
    
    return $true
}

function New-ProjectDirectories {
    Write-Status "Creating project directories..."
    
    $dirs = @("logs", "data/redis", "data/postgres", "ssl", "grafana/provisioning/dashboards", "grafana/provisioning/datasources")
    
    foreach ($dir in $dirs) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Status "Created directory: $dir"
        }
    }
    
    Write-Success "Directories created successfully"
}

function New-ConfigFiles {
    Write-Status "Creating configuration files..."
    
    # Create docker-compose.yml
    @"
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: chef_redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - chef_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5

  postgres:
    image: postgres:15-alpine
    container_name: chef_postgres
    environment:
      POSTGRES_DB: distributed_chef
      POSTGRES_USER: chef_admin
      POSTGRES_PASSWORD: chef_password_2024
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - chef_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chef_admin -d distributed_chef"]
      interval: 30s
      timeout: 10s
      retries: 5

  # Simple web server for the dashboard
  dashboard:
    image: nginx:alpine
    container_name: chef_dashboard
    ports:
      - "80:80"
    volumes:
      - ./dashboard.html:/usr/share/nginx/html/index.html:ro
      - ./animated_storyboard.html:/usr/share/nginx/html/storyboard.html:ro
    networks:
      - chef_network

  # Mock load balancer (simplified for demo)
  load_balancer:
    image: python:3.11-slim
    container_name: chef_load_balancer
    ports:
      - "8080:8080"
    volumes:
      - .:/app
    working_dir: /app
    command: python -c "
import json
import time
import random
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

class LoadBalancerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            response = {'status': 'healthy', 'timestamp': datetime.now().isoformat()}
            self.wfile.write(json.dumps(response).encode())
        elif self.path == '/api/status':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            kitchens = {
                'kitchen_1': {'name': 'Downtown Kitchen', 'load': random.randint(20, 80), 'capacity': 10, 'status': 'available'},
                'kitchen_2': {'name': 'Uptown Bistro', 'load': random.randint(20, 80), 'capacity': 12, 'status': 'available'},
                'kitchen_3': {'name': 'Suburb Deli', 'load': random.randint(20, 80), 'capacity': 8, 'status': 'available'},
                'kitchen_4': {'name': 'Express Kitchen', 'load': random.randint(20, 80), 'capacity': 15, 'status': 'available'}
            }
            response = {
                'kitchens': kitchens,
                'system_health': 'Healthy',
                'total_orders': random.randint(100, 500),
                'uptime': '99.9%'
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        if self.path == '/api/orders':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            order_id = f'order_{random.randint(1000, 9999)}'
            response = {'order_id': order_id, 'status': 'created'}
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8080), LoadBalancerHandler)
    print('Load Balancer Mock running on port 8080...')
    server.serve_forever()
"
    networks:
      - chef_network

  prometheus:
    image: prom/prometheus:latest
    container_name: chef_prometheus
    ports:
      - "9090:9090"
    networks:
      - chef_network

  grafana:
    image: grafana/grafana:latest
    container_name: chef_grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
    networks:
      - chef_network

networks:
  chef_network:
    driver: bridge

volumes:
  redis_data:
  postgres_data:
"@ | Out-File -FilePath "docker-compose.yml" -Encoding UTF8
    
    Write-Success "Docker Compose configuration created"
}

function Start-Services {
    Write-Status "Starting services with Docker Compose..."
    
    try {
        # Pull images first
        Write-Status "Pulling Docker images..."
        docker-compose pull
        
        # Start services
        Write-Status "Starting containers..."
        docker-compose up -d
        
        Write-Success "Services started successfully"
        return $true
    } catch {
        Write-Error-Custom "Failed to start services: $_"
        return $false
    }
}

function Wait-ForServices {
    Write-Status "Waiting for services to be ready..."
    
    $maxAttempts = 30
    $attempt = 0
    
    while ($attempt -lt $maxAttempts) {
        try {
            # Test Redis
            $redisStatus = docker exec chef_redis redis-cli ping 2>$null
            
            # Test Load Balancer
            $response = Invoke-WebRequest -Uri "http://localhost:8080/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
            
            if ($redisStatus -eq "PONG" -and $response.StatusCode -eq 200) {
                Write-Success "All services are ready!"
                return $true
            }
        } catch {
            # Services not ready yet
        }
        
        $attempt++
        Write-Status "Waiting for services... ($attempt/$maxAttempts)"
        Start-Sleep -Seconds 5
    }
    
    Write-Warning "Services may not be fully ready, but continuing..."
    return $false
}

function Test-System {
    Write-Status "Testing system endpoints..."
    
    try {
        # Test dashboard
        $dashboardResponse = Invoke-WebRequest -Uri "http://localhost:80" -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($dashboardResponse.StatusCode -eq 200) {
            Write-Success "Dashboard accessible at http://localhost:80"
        }
        
        # Test API
        $apiResponse = Invoke-WebRequest -Uri "http://localhost:8080/api/status" -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($apiResponse.StatusCode -eq 200) {
            Write-Success "API accessible at http://localhost:8080"
        }
        
        # Test Grafana
        $grafanaResponse = Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($grafanaResponse.StatusCode -eq 200) {
            Write-Success "Grafana accessible at http://localhost:3000"
        }
        
    } catch {
        Write-Warning "Some services may still be starting up"
    }
}

function Show-Summary {
    Write-Host ""
    Write-Host "🎉 Deployment completed!" -ForegroundColor Green
    Write-Host "================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Service URLs:" -ForegroundColor Yellow
    Write-Host "• Main Dashboard: http://localhost:80" -ForegroundColor White
    Write-Host "• Animated Storyboard: http://localhost:80/storyboard.html" -ForegroundColor White
    Write-Host "• Load Balancer API: http://localhost:8080" -ForegroundColor White
    Write-Host "• Grafana Dashboard: http://localhost:3000 (admin/admin123)" -ForegroundColor White
    Write-Host "• Prometheus: http://localhost:9090" -ForegroundColor White
    Write-Host ""
    Write-Host "Docker containers:" -ForegroundColor Yellow
    docker-compose ps
    Write-Host ""
    Write-Host "Useful commands:" -ForegroundColor Yellow
    Write-Host "• View logs: docker-compose logs -f [service_name]" -ForegroundColor White
    Write-Host "• Stop services: docker-compose down" -ForegroundColor White
    Write-Host "• Restart services: docker-compose restart" -ForegroundColor White
    Write-Host "• Cleanup: docker-compose down -v" -ForegroundColor White
}

function Stop-Services {
    Write-Status "Stopping all services..."
    docker-compose down -v
    Write-Success "Services stopped and volumes removed"
}

# Main execution
switch ($Action.ToLower()) {
    "deploy" {
        if (!(Test-Prerequisites)) {
            exit 1
        }
        
        New-ProjectDirectories
        New-ConfigFiles
        
        if (Start-Services) {
            Wait-ForServices
            Test-System
            Show-Summary
        } else {
            Write-Error-Custom "Deployment failed"
            exit 1
        }
    }
    
    "stop" {
        Stop-Services
    }
    
    "restart" {
        Write-Status "Restarting services..."
        docker-compose restart
        Wait-ForServices
        Write-Success "Services restarted"
    }
    
    "status" {
        Write-Status "Current system status:"
        docker-compose ps
        
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:8080/api/status" -ErrorAction SilentlyContinue
            Write-Host "`nAPI Status:" -ForegroundColor Yellow
            $response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 3
        } catch {
            Write-Warning "API not accessible"
        }
    }
    
    "logs" {
        docker-compose logs -f
    }
    
    default {
        Write-Host "Usage: .\deploy.ps1 [deploy|stop|restart|status|logs]" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Commands:" -ForegroundColor Yellow
        Write-Host "  deploy  - Deploy the entire system" -ForegroundColor White
        Write-Host "  stop    - Stop and remove all containers" -ForegroundColor White  
        Write-Host "  restart - Restart all services" -ForegroundColor White
        Write-Host "  status  - Show system status" -ForegroundColor White
        Write-Host "  logs    - Show logs from all services" -ForegroundColor White
    }
}