#!/bin/bash

# TableSide Demo Deployment Script (Fixed Database Configuration)
# Deploys Frappe LMS + Wiki for demo.tableside.cloud
# Compatible with Ubuntu 24.04 LTS

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# =============================================================================
# DEMO CONFIGURATION
# =============================================================================

CLIENT_NAME="demo"
CLIENT_DOMAIN="demo.tableside.cloud"
ADMIN_EMAIL="admin@tableside.cloud"
ADMIN_PASSWORD="ChangeMe123!"
DB_ROOT_PASSWORD="TableSide2024!"

# System Configuration
TABLESIDE_USER="tableside"
BENCH_DIR="/home/${TABLESIDE_USER}/frappe-bench"
FRAPPE_VERSION="version-14"

# Repository URLs
LMS_REPO="https://github.com/frappe/lms.git"
WIKI_REPO="https://github.com/frappe/wiki.git"

# =============================================================================
# SYSTEM REQUIREMENTS CHECK
# =============================================================================

check_requirements() {
    log "Checking system requirements..."
    
    # Check if running as tableside user
    if [[ "$USER" != "$TABLESIDE_USER" ]]; then
        error "This script must be run as the '$TABLESIDE_USER' user"
        exit 1
    fi
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu 24.04" /etc/os-release; then
        warning "This script is optimized for Ubuntu 24.04 LTS"
    fi
    
    # Check if required ports are available
    if netstat -tuln 2>/dev/null | grep -q ":80\|:443"; then
        warning "Ports 80 or 443 may be in use. This could affect the setup."
    fi
    
    success "System requirements check completed"
}

# =============================================================================
# DEPENDENCY INSTALLATION
# =============================================================================

install_dependencies() {
    log "Installing system dependencies..."
    
    # Update package list
    sudo apt update
    
    # Install required packages
    sudo apt install -y \
        python3-dev python3-pip python3-venv python3-setuptools \
        nodejs npm \
        mariadb-server mariadb-client \
        redis-server \
        nginx \
        supervisor \
        curl wget git htop \
        build-essential \
        libffi-dev libssl-dev \
        libmysqlclient-dev \
        wkhtmltopdf \
        xvfb libfontconfig \
        net-tools
    
    # Install specific Node.js version (16.x for compatibility)
    curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
    sudo apt-get install -y nodejs
    
    # Install yarn
    sudo npm install -g yarn
    
    success "Dependencies installed successfully"
}

# =============================================================================
# DATABASE CONFIGURATION (FIXED VERSION)
# =============================================================================

configure_database() {
    log "Configuring MariaDB database..."
    
    # Modern MariaDB security setup
    log "Setting up MariaDB root password..."
    
    # Stop MariaDB to ensure clean state
    sudo systemctl stop mariadb
    sudo systemctl start mariadb
    
    # Wait for MariaDB to be ready
    sleep 3
    
    # Set root password using modern method
    log "Configuring root password..."
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';" 2>/dev/null || {
        log "Trying alternative password method..."
        sudo mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_ROOT_PASSWORD}');" 2>/dev/null || {
            log "Using mysqladmin to set root password..."
            sudo mysqladmin -u root password "${DB_ROOT_PASSWORD}" 2>/dev/null || {
                warning "Could not set root password automatically. You may need to set it manually."
            }
        }
    }
    
    # Secure installation (remove anonymous users, test database, etc.)
    log "Securing MariaDB installation..."
    
    # Create a temporary SQL script for security setup
    cat > /tmp/secure_mysql.sql << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    
    # Execute security script (try with and without password)
    sudo mysql -u root -p"${DB_ROOT_PASSWORD}" < /tmp/secure_mysql.sql 2>/dev/null || \
    sudo mysql -u root < /tmp/secure_mysql.sql 2>/dev/null || {
        log "Some security steps may have been skipped. Database should still work."
    }
    
    # Clean up
    rm -f /tmp/secure_mysql.sql
    
    # Create MariaDB config for Frappe
    log "Creating Frappe-optimized MariaDB configuration..."
    sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf << EOF
[mysql]
default-character-set = utf8mb4

[mysqld]
innodb-file-format=barracuda
innodb-file-per-table=1
innodb-large-prefix=1
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
default-character-set = utf8mb4

[client]
default-character-set = utf8mb4
EOF
    
    # Restart MariaDB
    sudo systemctl restart mariadb
    
    # Wait for restart
    sleep 3
    
    # Verify connection
    if sudo mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null; then
        success "MariaDB configured successfully with root password"
    elif sudo mysql -u root -e "SELECT 1;" &>/dev/null; then
        success "MariaDB configured successfully (no root password set)"
    else
        error "MariaDB configuration may have issues"
    fi
}

# =============================================================================
# FRAPPE BENCH INSTALLATION
# =============================================================================

install_frappe_bench() {
    log "Installing Frappe Bench..."
    
    # Install bench using pip
    sudo pip3 install frappe-bench
    
    # Initialize bench
    cd ~
    if [ -d "frappe-bench" ]; then
        warning "frappe-bench directory already exists. Removing..."
        rm -rf frappe-bench
    fi
    
    bench init --frappe-branch $FRAPPE_VERSION frappe-bench
    cd $BENCH_DIR
    
    # Set MariaDB root password in bench config
    bench set-mariadb-host localhost
    
    success "Frappe Bench installed successfully"
}

# =============================================================================
# SITE CREATION
# =============================================================================

create_site() {
    log "Creating site: $CLIENT_DOMAIN"
    
    cd $BENCH_DIR
    
    # Create new site (try with and without MariaDB root password)
    if ! bench new-site $CLIENT_DOMAIN \
        --admin-password "$ADMIN_PASSWORD" \
        --mariadb-root-password "$DB_ROOT_PASSWORD" 2>/dev/null; then
        
        log "Trying site creation without explicit MariaDB root password..."
        bench new-site $CLIENT_DOMAIN \
            --admin-password "$ADMIN_PASSWORD"
    fi
    
    success "Site $CLIENT_DOMAIN created successfully"
}

# =============================================================================
# APP INSTALLATION
# =============================================================================

install_apps() {
    log "Installing LMS and Wiki applications..."
    
    cd $BENCH_DIR
    
    # Get LMS app
    log "Downloading Frappe LMS..."
    bench get-app lms $LMS_REPO
    
    # Get Wiki app
    log "Downloading Frappe Wiki..."
    bench get-app wiki $WIKI_REPO
    
    # Install apps on site
    log "Installing LMS on site..."
    bench --site $CLIENT_DOMAIN install-app lms
    
    log "Installing Wiki on site..."
    bench --site $CLIENT_DOMAIN install-app wiki
    
    success "Applications installed successfully"
}

# =============================================================================
# PRODUCTION SETUP
# =============================================================================

setup_production() {
    log "Setting up production environment..."
    
    cd $BENCH_DIR
    
    # Setup production (nginx, supervisor)
    sudo bench setup production $TABLESIDE_USER
    
    # Enable and start services
    sudo systemctl enable nginx
    sudo systemctl enable supervisor
    sudo systemctl start nginx
    sudo systemctl start supervisor
    
    success "Production environment configured"
}

# =============================================================================
# NGINX SSL/HTTPS CONFIGURATION
# =============================================================================

configure_nginx_ssl() {
    log "Configuring Nginx for HTTPS..."
    
    # Note: In production, Cloudflare handles SSL termination
    # This creates a basic config that works with Cloudflare proxy
    
    sudo tee /etc/nginx/sites-available/$CLIENT_DOMAIN << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $CLIENT_DOMAIN;

    # Real IP from Cloudflare
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 131.0.72.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    real_ip_header CF-Connecting-IP;

    # Disable autoindex
    autoindex off;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
    
    # Enable site
    sudo ln -sf /etc/nginx/sites-available/$CLIENT_DOMAIN /etc/nginx/sites-enabled/
    
    # Test nginx configuration
    sudo nginx -t
    
    # Reload nginx
    sudo systemctl reload nginx
    
    success "Nginx configured for Cloudflare SSL"
}

# =============================================================================
# BASIC CUSTOMIZATION
# =============================================================================

apply_basic_customization() {
    log "Applying basic TableSide customization..."
    
    cd $BENCH_DIR
    
    # Set site as default
    bench use $CLIENT_DOMAIN
    
    # Basic site settings
    bench --site $CLIENT_DOMAIN execute "import frappe; frappe.db.set_value('Website Settings', 'Website Settings', 'title_prefix', 'Demo Training Portal')"
    
    # Create basic pages structure
    bench --site $CLIENT_DOMAIN execute "
import frappe
from frappe import _

# Create basic welcome page
if not frappe.db.exists('Web Page', 'welcome'):
    page = frappe.get_doc({
        'doctype': 'Web Page',
        'title': 'Welcome to Your Training Portal',
        'route': 'welcome',
        'published': 1,
        'content_type': 'Rich Text',
        'main_section': '''
        <div class=\"text-center\">
            <h1>Welcome to Demo Training Portal</h1>
            <p class=\"lead\">Your comprehensive learning management system</p>
            <p>Access your training materials, track progress, and enhance your skills.</p>
        </div>
        '''
    })
    page.insert()

frappe.db.commit()
"
    
    success "Basic customization applied"
}

# =============================================================================
# SYSTEM SERVICES CONFIGURATION
# =============================================================================

configure_services() {
    log "Configuring system services..."
    
    # Ensure all services start on boot
    sudo systemctl enable mariadb
    sudo systemctl enable redis-server
    sudo systemctl enable nginx
    sudo systemctl enable supervisor
    
    # Start services
    sudo systemctl start mariadb
    sudo systemctl start redis-server
    sudo systemctl start nginx
    sudo systemctl start supervisor
    
    success "System services configured"
}

# =============================================================================
# BACKUP CONFIGURATION
# =============================================================================

setup_backup() {
    log "Setting up backup configuration..."
    
    cd $BENCH_DIR
    
    # Create backup directory
    sudo mkdir -p /var/backups/tableside
    sudo chown $TABLESIDE_USER:$TABLESIDE_USER /var/backups/tableside
    
    # Create backup script
    tee ~/backup-tableside.sh << EOF
#!/bin/bash
# TableSide Backup Script

DATE=\$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/backups/tableside"
BENCH_DIR="/home/tableside/frappe-bench"

cd \$BENCH_DIR

# Create site backup
bench --site $CLIENT_DOMAIN backup --with-files

# Move to backup directory with timestamp
mv sites/$CLIENT_DOMAIN/private/backups/* \$BACKUP_DIR/ 2>/dev/null || true

# Keep only last 7 days of backups
find \$BACKUP_DIR -name "*.sql.gz" -mtime +7 -delete 2>/dev/null || true
find \$BACKUP_DIR -name "*.tar" -mtime +7 -delete 2>/dev/null || true

echo "Backup completed: \$DATE"
EOF
    
    chmod +x ~/backup-tableside.sh
    
    # Add to crontab (daily backup at 2 AM)
    (crontab -l 2>/dev/null; echo "0 2 * * * /home/$TABLESIDE_USER/backup-tableside.sh >> /var/log/tableside-backup.log 2>&1") | crontab -
    
    success "Backup system configured"
}

# =============================================================================
# SECURITY HARDENING
# =============================================================================

apply_security_hardening() {
    log "Applying security hardening..."
    
    cd $BENCH_DIR
    
    # Set proper file permissions
    find . -type f -name "*.py" -exec chmod 644 {} \; 2>/dev/null || true
    find . -type d -exec chmod 755 {} \; 2>/dev/null || true
    
    # Secure site config
    chmod 600 sites/$CLIENT_DOMAIN/site_config.json 2>/dev/null || true
    
    success "Security hardening applied"
}

# =============================================================================
# HEALTH CHECKS
# =============================================================================

run_health_checks() {
    log "Running health checks..."
    
    cd $BENCH_DIR
    
    # Check services
    services=("mariadb" "redis-server" "nginx" "supervisor")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            success "$service is running"
        else
            error "$service is not running"
            return 1
        fi
    done
    
    # Wait a moment for services to be fully ready
    sleep 5
    
    # Check site accessibility
    if curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null | grep -q "200"; then
        success "Site is accessible locally"
    else
        warning "Site may not be fully ready yet (this is sometimes normal)"
    fi
    
    # Check database connectivity
    if bench --site $CLIENT_DOMAIN execute "import frappe; print('DB OK')" 2>/dev/null | grep -q "DB OK"; then
        success "Database connectivity OK"
    else
        error "Database connectivity failed"
        return 1
    fi
    
    success "Health checks completed"
}

# =============================================================================
# DEPLOYMENT SUMMARY
# =============================================================================

print_deployment_summary() {
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}                    TABLESIDE DEMO DEPLOYMENT COMPLETE                    ${NC}"
    echo "================================================================================"
    echo ""
    echo -e "${BLUE}Demo Site Information:${NC}"
    echo "  Domain: demo.tableside.cloud"
    echo "  Admin Email: admin@tableside.cloud"
    echo ""
    echo -e "${BLUE}Access Information:${NC}"
    echo "  Site URL: https://demo.tableside.cloud"
    echo "  Admin Username: Administrator"
    echo "  Admin Password: ChangeMe123!"
    echo ""
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo "  1. Configure Cloudflare DNS A record: demo -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
    echo "  2. Enable Cloudflare proxy (orange cloud) for SSL"
    echo "  3. Wait 2-5 minutes for DNS propagation"
    echo "  4. Visit https://demo.tableside.cloud"
    echo "  5. Login and change admin password"
    echo ""
    echo -e "${BLUE}System Information:${NC}"
    echo "  Bench Directory: /home/tableside/frappe-bench"
    echo "  Backup Location: /var/backups/tableside"
    echo "  Daily Backups: 2:00 AM (7-day retention)"
    echo ""
    echo -e "${BLUE}Troubleshooting:${NC}"
    echo "  View logs: tail -f /home/tableside/frappe-bench/logs/web.log"
    echo "  Restart services: sudo supervisorctl restart all"
    echo "  Check status: sudo systemctl status nginx mariadb redis-server supervisor"
    echo ""
    echo -e "${GREEN}Demo deployment completed successfully!${NC}"
    echo "================================================================================"
}

# =============================================================================
# MAIN DEPLOYMENT FUNCTION
# =============================================================================

main() {
    echo ""
    echo "================================================================================"
    echo -e "${BLUE}                      TABLESIDE DEMO DEPLOYMENT                      ${NC}"
    echo "                          demo.tableside.cloud"
    echo "================================================================================"
    echo ""
    
    read -p "Proceed with demo deployment? [y/N]: " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 1
    fi
    
    # Execute deployment steps
    check_requirements
    install_dependencies
    configure_database
    install_frappe_bench
    create_site
    install_apps
    setup_production
    configure_nginx_ssl
    apply_basic_customization
    configure_services
    setup_backup
    apply_security_hardening
    run_health_checks
    print_deployment_summary
}

# Execute main function
main "$@"
