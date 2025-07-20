#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}--------$1--------${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        print_error "Cannot detect operating system"
        exit 1
    fi
    
    if [[ "$OS" != *"Ubuntu"* ]] && [[ "$OS" != *"Debian"* ]]; then
        print_error "This script only supports Ubuntu and Debian"
        exit 1
    fi
}

install_mysql() {
    print_status "Installing MySQL"
    
    export DEBIAN_FRONTEND=noninteractive
    
    apt update
    
    apt install -y mysql-server
    
    if [[ $? -eq 0 ]]; then
        print_success "MySQL installed successfully"
    else
        print_error "MySQL installation failed"
        exit 1
    fi
    
    systemctl start mysql
    systemctl enable mysql
    
    print_status "Waiting for MySQL to be ready..."
    for i in {1..30}; do
        if systemctl is-active --quiet mysql; then
            print_success "MySQL service started and enabled"
            return 0
        fi
        sleep 2
    done
    
    print_error "MySQL service failed to start"
    exit 1
}

secure_mysql() {
    print_status "Manually securing MySQL installation (bypassing mysql_secure_installation)"
    
    print_status "Waiting for MySQL to be ready..."
    sleep 15
    
    MYSQL_CMD=""
    
    if mysql -u root -e "SELECT 1;" 2>/dev/null; then
        MYSQL_CMD="mysql -u root"
        print_success "Connected as root directly"
    elif sudo mysql -e "SELECT 1;" 2>/dev/null; then
        MYSQL_CMD="sudo mysql"
        print_success "Connected using sudo mysql"
    elif mysql -u root -p'' -e "SELECT 1;" 2>/dev/null; then
        MYSQL_CMD="mysql -u root -p''"
        print_success "Connected with empty root password"
    elif mysql --socket=/var/run/mysqld/mysqld.sock -u root -e "SELECT 1;" 2>/dev/null; then
        MYSQL_CMD="mysql --socket=/var/run/mysqld/mysqld.sock -u root"
        print_success "Connected using socket authentication"
    else
        print_error "Cannot connect to MySQL with any method"
        print_warning "Trying to reset MySQL root access..."
        
        systemctl stop mysql
        
        mysqld_safe --skip-grant-tables --skip-networking &
        SAFE_PID=$!
        sleep 10
        
        if mysql -u root -e "UPDATE mysql.user SET authentication_string=NULL WHERE User='root' AND Host='localhost'; FLUSH PRIVILEGES;" 2>/dev/null; then
            print_success "Root access reset"
            kill $SAFE_PID 2>/dev/null || true
            systemctl start mysql
            sleep 10
            MYSQL_CMD="mysql -u root"
        else
            print_error "Failed to reset root access"
            kill $SAFE_PID 2>/dev/null || true
            exit 1
        fi
    fi
    
    print_success "MySQL connection method established: $MYSQL_CMD"
    
    print_status "Applying security configurations..."
    
    print_status "Removing anonymous users..."
    if $MYSQL_CMD -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null; then
        print_success "Anonymous users removed"
    else
        print_warning "Failed to remove anonymous users (may not exist)"
    fi
    
    print_status "Removing remote root access..."
    if $MYSQL_CMD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null; then
        print_success "Remote root access removed"
    else
        print_warning "Failed to remove remote root access (may not exist)"
    fi
    
    print_status "Removing test database..."
    if $MYSQL_CMD -e "DROP DATABASE IF EXISTS test;" 2>/dev/null; then
        print_success "Test database removed"
    else
        print_warning "Test database not found (already removed or never existed)"
    fi
    
    if $MYSQL_CMD -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null; then
        print_success "Test database privileges removed"
    else
        print_warning "No test database privileges found"
    fi
    
    print_status "Configuring root authentication..."
    
    MYSQL_VERSION=$($MYSQL_CMD -e "SELECT VERSION();" -s -N 2>/dev/null | cut -d. -f1)
    if [[ "$MYSQL_VERSION" -ge 8 ]]; then
        print_status "Detected MySQL 8.0+, configuring authentication..."
        $MYSQL_CMD -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';" 2>/dev/null || true
        $MYSQL_CMD -e "ALTER USER 'root'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '';" 2>/dev/null || true
    fi
    
    print_status "Flushing privileges..."
    if $MYSQL_CMD -e "FLUSH PRIVILEGES;" 2>/dev/null; then
        print_success "Privileges flushed successfully"
    else
        print_error "Failed to flush privileges"
        exit 1
    fi
    
    sleep 5
    if mysql -u root -e "SELECT 1;" 2>/dev/null || sudo mysql -e "SELECT 1;" 2>/dev/null; then
        print_success "MySQL manual security configuration completed successfully"
    else
        print_error "MySQL security configuration may have issues"
        print_warning "Continuing anyway - please test manually later"
    fi
    
    echo "$MYSQL_CMD" > /tmp/mysql_cmd_pelican
}

create_database_host() {
    print_status "Creating Database Host User..."
    
    MYSQL_CMD="mysql -u root"
    if [[ -f /tmp/mysql_cmd_pelican ]]; then
        MYSQL_CMD=$(cat /tmp/mysql_cmd_pelican)
        rm -f /tmp/mysql_cmd_pelican
    fi
    
    while true; do
        echo -n "Enter password for pelicanuser (minimum 8 characters): "
        read -s DB_PASSWORD
        echo ""
        
        if [[ -z "$DB_PASSWORD" ]]; then
            print_error "Database password cannot be empty"
            continue
        fi
        
        if [[ ${#DB_PASSWORD} -lt 8 ]]; then
            print_error "Password must be at least 8 characters long"
            continue
        fi
        
        echo -n "Confirm password: "
        read -s DB_PASSWORD_CONFIRM
        echo ""
        
        if [[ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]]; then
            print_error "Passwords do not match"
            continue
        fi
        
        break
    done
    
    print_status "Creating pelicanuser for localhost..."
    if $MYSQL_CMD -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null; then
        print_success "User pelicanuser@localhost created"
    else
        print_warning "User pelicanuser@localhost may already exist"
    fi
    
    if $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'localhost' WITH GRANT OPTION;" 2>/dev/null; then
        print_success "Privileges granted to pelicanuser@localhost"
    else
        print_error "Failed to grant privileges to pelicanuser@localhost"
    fi
    
    print_status "Creating pelicanuser for 127.0.0.1..."
    if $MYSQL_CMD -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null; then
        print_success "User pelicanuser@127.0.0.1 created"
    else
        print_warning "User pelicanuser@127.0.0.1 may already exist"
    fi
    
    if $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'127.0.0.1' WITH GRANT OPTION;" 2>/dev/null; then
        print_success "Privileges granted to pelicanuser@127.0.0.1"
    else
        print_error "Failed to grant privileges to pelicanuser@127.0.0.1"
    fi
    
    print_status "Creating pelicanuser for external access..."
    if $MYSQL_CMD -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'%' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null; then
        print_success "User pelicanuser@% created for external access"
    else
        print_warning "User pelicanuser@% may already exist"
    fi
    
    if $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'%' WITH GRANT OPTION;" 2>/dev/null; then
        print_success "Privileges granted to pelicanuser@% for external access"
    else
        print_error "Failed to grant privileges to pelicanuser@%"
    fi
    
    if $MYSQL_CMD -e "FLUSH PRIVILEGES;" 2>/dev/null; then
        print_success "Privileges flushed"
    else
        print_error "Failed to flush privileges"
    fi
    
    print_status "Testing database user connection..."
    if mysql -u pelicanuser -p"$DB_PASSWORD" -h 127.0.0.1 -e "SELECT 1;" 2>/dev/null; then
        print_success "Database user connection test successful"
    elif mysql -u pelicanuser -p"$DB_PASSWORD" -h localhost -e "SELECT 1;" 2>/dev/null; then
        print_success "Database user connection test successful (localhost)"
    else
        print_warning "Database user created but connection test failed"
        print_warning "This might be normal if external connections aren't configured yet"
    fi
}

allow_external_access() {
    print_status "Configuring MySQL for external access..."
    
    MYCNF_FILE=""
    
    for file in "/etc/mysql/mysql.conf.d/mysqld.cnf" "/etc/mysql/mariadb.conf.d/50-server.cnf" "/etc/mysql/my.cnf" "/etc/my.cnf"; do
        if [[ -f "$file" ]]; then
            MYCNF_FILE="$file"
            break
        fi
    done
    
    if [[ -z "$MYCNF_FILE" ]]; then
        mkdir -p /etc/mysql/conf.d
        MYCNF_FILE="/etc/mysql/conf.d/pelican.cnf"
        cat > "$MYCNF_FILE" << EOF
[mysqld]
bind-address = 0.0.0.0
max_connections = 200
EOF
        print_success "Created new configuration file: $MYCNF_FILE"
    else
        print_status "Updating configuration file: $MYCNF_FILE"
        
        cp "$MYCNF_FILE" "${MYCNF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup created: ${MYCNF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        
        if grep -q "^bind-address" "$MYCNF_FILE"; then
            sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$MYCNF_FILE"
            print_success "Updated existing bind-address setting"
        elif grep -q "^\s*#.*bind-address" "$MYCNF_FILE"; then
            sed -i 's/^\s*#.*bind-address.*/bind-address = 0.0.0.0/' "$MYCNF_FILE"
            print_success "Uncommented and updated bind-address setting"
        else
            if grep -q "^\[mysqld\]" "$MYCNF_FILE"; then
                sed -i '/^\[mysqld\]/a bind-address = 0.0.0.0' "$MYCNF_FILE"
                print_success "Added bind-address to [mysqld] section"
            else
                echo -e "\n[mysqld]\nbind-address = 0.0.0.0" >> "$MYCNF_FILE"
                print_success "Added [mysqld] section with bind-address"
            fi
        fi
    fi
    
    if mysqld --help --verbose > /dev/null 2>&1; then
        print_success "MySQL configuration syntax validated"
    else
        print_error "MySQL configuration has syntax errors"
        print_warning "Restoring backup configuration"
        if [[ -f "${MYCNF_FILE}.backup.$(date +%Y%m%d_%H%M%S)" ]]; then
            mv "${MYCNF_FILE}.backup.$(date +%Y%m%d_%H%M%S)" "$MYCNF_FILE"
        fi
        exit 1
    fi
    
    print_status "Restarting MySQL service..."
    systemctl restart mysql
    
    sleep 5
    
    if systemctl is-active --quiet mysql; then
        print_success "MySQL restarted successfully"
        
        if netstat -tlnp 2>/dev/null | grep -q ":3306.*0.0.0.0"; then
            print_success "MySQL is now accepting external connections on port 3306"
        else
            print_warning "MySQL may not be binding to external interfaces - please verify manually"
        fi
    else
        print_error "MySQL restart failed"
        print_warning "Checking MySQL status and logs..."
        systemctl status mysql --no-pager
        print_warning "Check logs with: journalctl -u mysql -n 20"
        exit 1
    fi
}

setup_firewall() {
    print_status "Setting up firewall rules..."
    
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow 3306/tcp
            print_success "UFW rule added for MySQL port 3306"
        else
            print_warning "UFW is installed but not active"
            print_warning "To enable UFW and allow MySQL: ufw enable && ufw allow 3306/tcp"
        fi
    elif command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=3306/tcp
            firewall-cmd --reload
            print_success "Firewalld rule added for MySQL port 3306"
        else
            print_warning "Firewalld is installed but not active"
        fi
    else
        print_warning "No supported firewall detected (UFW/firewalld)"
        print_warning "Please manually ensure port 3306 is accessible"
        print_warning "Example for iptables: iptables -A INPUT -p tcp --dport 3306 -j ACCEPT"
    fi
}

display_completion() {
    print_status "Installation Complete!"
    echo ""
    print_success "Pelican Database Host installation completed successfully!"
    echo ""
    echo -e "${YELLOW}📋 Database Connection Details:${NC}"
    echo "┌─────────────────────────────────────────┐"
    echo "│ Username: pelicanuser                   │"
    echo "│ Host: 127.0.0.1 (or your server IP)    │"
    echo "│ Port: 3306                              │"
    echo "│ Password: [the one you set]             │"
    echo "└─────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}🚀 Next Steps:${NC}"
    echo "1. Go to your Pelican Admin Panel"
    echo "2. Navigate to Database Hosts"
    echo "3. Click 'Create Database Host'"
    echo "4. Enter the connection details above"
    echo "5. Test the connection"
    echo ""
    echo -e "${YELLOW}🔧 Additional Notes:${NC}"
    echo "• The user 'pelicanuser' has full privileges"
    echo "• MySQL is configured to accept external connections"
    echo "• Make sure your network security allows port 3306"
    echo "• Consider using SSL for production environments"
    echo ""
    echo -e "${GREEN}✨ Made by: Verdanox${NC}"
}

main() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           PELICAN DATABASE HOST INSTALLATION              ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${GREEN}Made by: Verdanox${NC}"
    echo ""
    
    check_root
    detect_os
    
    print_warning "Installing Pelican Database Host on your server..."
    print_warning "Operating System: $OS $VERSION"
    echo ""
    
    echo -e "${YELLOW}This script will:${NC}"
    echo "• Install MySQL Server"
    echo "• Secure the MySQL installation"
    echo "• Create a database user 'pelicanuser'"
    echo "• Configure MySQL for external connections"
    echo "• Set up firewall rules"
    echo ""
    
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Installation cancelled by user"
        exit 0
    fi
    
    install_mysql
    secure_mysql
    create_database_host
    allow_external_access
    setup_firewall
    display_completion
}

main "$@"
