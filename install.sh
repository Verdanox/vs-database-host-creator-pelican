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
        OS_ID=$ID
    else
        print_error "Cannot detect operating system"
        exit 1
    fi
    
    if [[ "$OS" != *"Ubuntu"* ]] && [[ "$OS" != *"Debian"* ]]; then
        print_error "This script only supports Ubuntu and Debian"
        exit 1
    fi
}

install_dependencies() {
    print_status "Installing required dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -y nginx php-fpm php-mysql php-mbstring php-zip php-gd php-json php-curl unzip wget curl net-tools
    if [[ $? -eq 0 ]]; then
        print_success "Dependencies installed successfully"
    else
        print_error "Failed to install dependencies"
        exit 1
    fi
}

install_mysql() {
    print_status "Installing MySQL/MariaDB"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    if [[ "$OS_ID" == "debian" ]]; then
        print_status "Debian detected, installing MariaDB as MySQL-compatible server"
        apt install -y mariadb-server mariadb-client
    else
        print_status "Ubuntu detected, installing MySQL Server"
        apt install -y mysql-server mysql-client
    fi
    if [[ $? -eq 0 ]]; then
        print_success "MySQL/MariaDB installed successfully"
    else
        print_error "MySQL/MariaDB installation failed"
        exit 1
    fi
    SERVICE_NAME="mysql"
    if systemctl list-units --full -all | grep -q "mariadb.service"; then
        SERVICE_NAME="mariadb"
    fi
    systemctl start $SERVICE_NAME
    systemctl enable $SERVICE_NAME
    print_status "Waiting for MySQL/MariaDB to be ready..."
    for i in {1..30}; do
        if systemctl is-active --quiet $SERVICE_NAME; then
            print_success "MySQL/MariaDB service started and enabled"
            return 0
        fi
        sleep 2
    done
    print_error "MySQL/MariaDB service failed to start"
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
    elif mysql --socket=/run/mysqld/mysqld.sock -u root -e "SELECT 1;" 2>/dev/null; then
        MYSQL_CMD="mysql --socket=/run/mysqld/mysqld.sock -u root"
        print_success "Connected using alternative socket path"
    else
        print_error "Cannot connect to MySQL with any method"
        print_warning "Trying to reset MySQL root access..."
        
        SERVICE_NAME="mysql"
        if systemctl list-units --full -all | grep -q "mariadb.service"; then
            SERVICE_NAME="mariadb"
        fi
        
        systemctl stop $SERVICE_NAME
        
        if command -v mysqld_safe >/dev/null 2>&1; then
            mysqld_safe --skip-grant-tables --skip-networking &
            SAFE_PID=$!
        elif command -v mariadbd-safe >/dev/null 2>&1; then
            mariadbd-safe --skip-grant-tables --skip-networking &
            SAFE_PID=$!
        else
            print_error "Cannot find mysqld_safe or mariadbd-safe"
            exit 1
        fi
        
        sleep 10
        
        if mysql -u root -e "UPDATE mysql.user SET authentication_string=NULL WHERE User='root' AND Host='localhost'; FLUSH PRIVILEGES;" 2>/dev/null; then
            print_success "Root access reset"
            kill $SAFE_PID 2>/dev/null || true
            systemctl start $SERVICE_NAME
            sleep 10
            MYSQL_CMD="mysql -u root"
        else
            print_error "Failed to reset root access"
            kill $SAFE_PID 2>/dev/null || true
            exit 1
        fi
    fi
    
    print_success "MySQL connection method established: $MYSQL_CMD"
    
    print_status "Applying security configurations manually..."
    
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
    
    DB_VERSION=$($MYSQL_CMD -e "SELECT VERSION();" -s -N 2>/dev/null)
    if [[ "$DB_VERSION" == *"MariaDB"* ]]; then
        print_status "Detected MariaDB, configuring authentication..."
        $MYSQL_CMD -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password;" 2>/dev/null || true
    else
        MYSQL_VERSION=$(echo "$DB_VERSION" | cut -d. -f1)
        if [[ "$MYSQL_VERSION" -ge 8 ]]; then
            print_status "Detected MySQL 8.0+, configuring authentication..."
            $MYSQL_CMD -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';" 2>/dev/null || true
            $MYSQL_CMD -e "ALTER USER 'root'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '';" 2>/dev/null || true
        fi
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
    
    DB_PASSWORD=""
    
    if [[ -t 0 ]] && [[ -t 1 ]]; then
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
    else
        print_warning "Non-interactive mode detected - generating secure password..."
        DB_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        print_success "Generated secure password for pelicanuser"
        echo ""
        print_warning "⚠️  IMPORTANT: Save this password - you'll need it for Pelican!"
        echo -e "${YELLOW}Generated Password: ${DB_PASSWORD}${NC}"
        echo ""
        sleep 5
    fi
    
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
    
    echo "$DB_PASSWORD" > /tmp/pelican_db_password
    echo "$MYSQL_CMD" > /tmp/mysql_cmd_pelican
}

install_phpmyadmin() {
    print_status "Installing phpMyAdmin"
    
    # Download and extract phpMyAdmin
    cd /usr/share
    print_status "Downloading phpMyAdmin..."
    if wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip -O phpmyadmin.zip; then
        print_success "phpMyAdmin downloaded successfully"
    else
        print_error "Failed to download phpMyAdmin"
        exit 1
    fi
    
    print_status "Extracting phpMyAdmin..."
    if unzip -q phpmyadmin.zip; then
        print_success "phpMyAdmin extracted successfully"
    else
        print_error "Failed to extract phpMyAdmin"
        exit 1
    fi
    
    rm phpmyadmin.zip
    mv phpMyAdmin-*-all-languages phpmyadmin
    chmod -R 0755 phpmyadmin
    
    # Create temp directory
    mkdir -p /usr/share/phpmyadmin/tmp/
    chown -R www-data:www-data /usr/share/phpmyadmin/tmp/
    
    print_success "phpMyAdmin files installed successfully"
}

configure_phpmyadmin_user() {
    print_status "Setting up phpMyAdmin database user"
    
    MYSQL_CMD="mysql -u root"
    if [[ -f /tmp/mysql_cmd_pelican ]]; then
        MYSQL_CMD=$(cat /tmp/mysql_cmd_pelican)
    fi
    
    PMA_PASSWORD=""
    
    if [[ -t 0 ]] && [[ -t 1 ]]; then
        while true; do
            echo -n "Enter password for phpMyAdmin user 'pma' (minimum 8 characters): "
            read -s PMA_PASSWORD
            echo ""
            
            if [[ -z "$PMA_PASSWORD" ]]; then
                print_error "phpMyAdmin password cannot be empty"
                continue
            fi
            
            if [[ ${#PMA_PASSWORD} -lt 8 ]]; then
                print_error "Password must be at least 8 characters long"
                continue
            fi
            
            echo -n "Confirm password: "
            read -s PMA_PASSWORD_CONFIRM
            echo ""
            
            if [[ "$PMA_PASSWORD" != "$PMA_PASSWORD_CONFIRM" ]]; then
                print_error "Passwords do not match"
                continue
            fi
            
            break
        done
    else
        print_warning "Non-interactive mode detected - generating secure password for phpMyAdmin..."
        PMA_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        print_success "Generated secure password for pma user"
        echo ""
        print_warning "⚠️  IMPORTANT: Save this password for phpMyAdmin!"
        echo -e "${YELLOW}phpMyAdmin Password: ${PMA_PASSWORD}${NC}"
        echo ""
        sleep 5
    fi
    
    # Create phpMyAdmin user
    print_status "Creating phpMyAdmin user 'pma'@'localhost'..."
    if $MYSQL_CMD -e "CREATE USER IF NOT EXISTS 'pma'@'localhost' IDENTIFIED BY '$PMA_PASSWORD';" 2>/dev/null; then
        print_success "User pma@localhost created"
    else
        print_warning "User pma@localhost may already exist"
    fi
    
    if $MYSQL_CMD -e "GRANT ALL PRIVILEGES ON *.* TO 'pma'@'localhost' WITH GRANT OPTION;" 2>/dev/null; then
        print_success "All privileges granted to pma@localhost"
    else
        print_error "Failed to grant privileges to pma@localhost"
    fi
    
    if $MYSQL_CMD -e "FLUSH PRIVILEGES;" 2>/dev/null; then
        print_success "Privileges flushed"
    else
        print_error "Failed to flush privileges"
    fi
    
    echo "$PMA_PASSWORD" > /tmp/pma_password
}

setup_nginx_phpmyadmin() {
    print_status "Configuring Nginx for phpMyAdmin"
    
    FQDN=""
    USE_PORT=""
    
    if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo -n "Enter your FQDN (domain) or IP address: "
        read FQDN
    else
        print_warning "Non-interactive mode: Using localhost as FQDN"
        FQDN="localhost"
    fi
    
    # Check if it's an IP address or domain
    if [[ $FQDN =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_status "IP address detected: $FQDN"
        # Check if port 80 is already in use
        if netstat -tlnp 2>/dev/null | grep -q ":80 " || ss -tlnp 2>/dev/null | grep -q ":80 "; then
            print_warning "Port 80 is already in use, using port 1024"
            USE_PORT="1024"
        else
            USE_PORT="80"
        fi
    else
        print_status "Domain detected: $FQDN"
        USE_PORT="80"
    fi
    
    # Get PHP version
    PHP_VERSION=$(php -v | head -n1 | cut -d" " -f2 | cut -f1-2 -d".")
    
    # Create Nginx configuration
    cat > /etc/nginx/sites-available/phpmyadmin.conf << EOF
server {
    listen $USE_PORT;
    server_name $FQDN;
    root /usr/share/phpmyadmin;
    index index.php index.html index.htm;

    access_log /var/log/nginx/phpmyadmin_access.log;
    error_log /var/log/nginx/phpmyadmin_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        log_not_found off;
        access_log off;
        allow all;
    }

    location ~* \.(css|gif|ico|jpeg|jpg|js|png)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    print_success "Nginx configuration created"
    
    # Enable the site
    if [[ -f /etc/nginx/sites-available/phpmyadmin.conf ]]; then
        ln -sf /etc/nginx/sites-available/phpmyadmin.conf /etc/nginx/sites-enabled/
        print_success "phpMyAdmin site enabled"
    else
        print_error "Failed to create Nginx configuration"
        exit 1
    fi
    
    # Test Nginx configuration
    if nginx -t 2>/dev/null; then
        print_success "Nginx configuration syntax is valid"
    else
        print_error "Nginx configuration syntax error"
        nginx -t
        exit 1
    fi
    
    # Start and enable services
    systemctl enable nginx php$PHP_VERSION-fpm
    systemctl restart nginx php$PHP_VERSION-fpm
    
    if systemctl is-active --quiet nginx && systemctl is-active --quiet php$PHP_VERSION-fpm; then
        print_success "Nginx and PHP-FPM services started successfully"
    else
        print_error "Failed to start web services"
        exit 1
    fi
    
    echo "$FQDN:$USE_PORT" > /tmp/phpmyadmin_url
}

allow_external_access() {
    print_status "Configuring MySQL for external access..."
    
    MYCNF_FILE=""
    
    for file in "/etc/mysql/mysql.conf.d/mysqld.cnf" "/etc/mysql/mariadb.conf.d/50-server.cnf" "/etc/mysql/my.cnf" "/etc/my.cnf" "/etc/mysql/conf.d/mysql.cnf"; do
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
    
    if command -v mysqld >/dev/null 2>&1; then
        if mysqld --help --verbose > /dev/null 2>&1; then
            print_success "MySQL configuration syntax validated"
        else
            print_warning "MySQL configuration syntax check failed, but continuing"
        fi
    elif command -v mariadbd >/dev/null 2>&1; then
        if mariadbd --help --verbose > /dev/null 2>&1; then
            print_success "MariaDB configuration syntax validated"
        else
            print_warning "MariaDB configuration syntax check failed, but continuing"
        fi
    fi
    
    SERVICE_NAME="mysql"
    if systemctl list-units --full -all | grep -q "mariadb.service"; then
        SERVICE_NAME="mariadb"
    fi
    
    print_status "Restarting $SERVICE_NAME service..."
    systemctl restart $SERVICE_NAME
    
    sleep 5
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_success "$SERVICE_NAME restarted successfully"
        
        if netstat -tlnp 2>/dev/null | grep -q ":3306.*0.0.0.0" || ss -tlnp 2>/dev/null | grep -q ":3306.*0.0.0.0"; then
            print_success "MySQL/MariaDB is now accepting external connections on port 3306"
        else
            print_warning "MySQL/MariaDB may not be binding to external interfaces - please verify manually"
        fi
    else
        print_error "$SERVICE_NAME restart failed"
        print_warning "Checking $SERVICE_NAME status and logs..."
        systemctl status $SERVICE_NAME --no-pager
        print_warning "Check logs with: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
}

setup_firewall() {
    print_status "Setting up firewall rules..."
    
    PHPMYADMIN_PORT=""
    if [[ -f /tmp/phpmyadmin_url ]]; then
        PHPMYADMIN_URL=$(cat /tmp/phpmyadmin_url)
        PHPMYADMIN_PORT=$(echo "$PHPMYADMIN_URL" | cut -d: -f2)
    fi
    
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow 3306/tcp
            print_success "UFW rule added for MySQL port 3306"
            
            if [[ -n "$PHPMYADMIN_PORT" ]]; then
                ufw allow $PHPMYADMIN_PORT/tcp
                print_success "UFW rule added for phpMyAdmin port $PHPMYADMIN_PORT"
            fi
        else
            print_warning "UFW is installed but not active"
            print_warning "To enable UFW and allow ports: ufw enable && ufw allow 3306/tcp"
            if [[ -n "$PHPMYADMIN_PORT" ]]; then
                print_warning "Also allow phpMyAdmin port: ufw allow $PHPMYADMIN_PORT/tcp"
            fi
        fi
    elif command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=3306/tcp
            if [[ -n "$PHPMYADMIN_PORT" ]]; then
                firewall-cmd --permanent --add-port=$PHPMYADMIN_PORT/tcp
            fi
            firewall-cmd --reload
            print_success "Firewalld rules added for MySQL and phpMyAdmin"
        else
            print_warning "Firewalld is installed but not active"
        fi
    else
        print_warning "No supported firewall detected (UFW/firewalld)"
        print_warning "Please manually ensure ports 3306 and $PHPMYADMIN_PORT are accessible"
    fi
}

display_completion() {
    print_status "Installation Complete!"
    echo ""
    print_success "Pelican Database Host with phpMyAdmin installation completed successfully!"
    echo ""
    
    DB_PASSWORD=""
    PMA_PASSWORD=""
    PHPMYADMIN_URL=""
    
    if [[ -f /tmp/pelican_db_password ]]; then
        DB_PASSWORD=$(cat /tmp/pelican_db_password)
        rm -f /tmp/pelican_db_password
    fi
    
    if [[ -f /tmp/pma_password ]]; then
        PMA_PASSWORD=$(cat /tmp/pma_password)
        rm -f /tmp/pma_password
    fi
    
    if [[ -f /tmp/phpmyadmin_url ]]; then
        PHPMYADMIN_URL=$(cat /tmp/phpmyadmin_url)
        rm -f /tmp/phpmyadmin_url
    fi
    
    echo -e "${YELLOW}📋 Database Connection Details:${NC}"
    echo "┌─────────────────────────────────────────┐"
    echo "│ Username: pelicanuser                   │"
    echo "│ Host: 127.0.0.1 (or your server IP)    │"
    echo "│ Port: 3306                              │"
    if [[ -n "$DB_PASSWORD" ]]; then
    echo "│ Password: $DB_PASSWORD                    │"
    else
    echo "│ Password: [the one you set]             │"
    fi
    echo "└─────────────────────────────────────────┘"
    echo ""
    
    if [[ -n "$PHPMYADMIN_URL" ]]; then
        echo -e "${YELLOW}🌐 phpMyAdmin Access:${NC}"
        echo "┌─────────────────────────────────────────┐"
        echo "│ URL: http://$PHPMYADMIN_URL              │"
        echo "│ Username: pma                           │"
        if [[ -n "$PMA_PASSWORD" ]]; then
        echo "│ Password: $PMA_PASSWORD                   │"
        else
        echo "│ Password: [the one you set]             │"
        fi
        echo "└─────────────────────────────────────────┘"
        echo ""
    fi
    
    echo -e "${YELLOW}🚀 Next Steps:${NC}"
    echo "1. Go to your Pelican Admin Panel"
    echo "2. Navigate to Database Hosts"
    echo "3. Click 'Create Database Host'"
    echo "4. Enter the connection details above"
    echo "5. Test the connection"
    if [[ -n "$PHPMYADMIN_URL" ]]; then
        echo "6. Access phpMyAdmin at http://$PHPMYADMIN_URL"
    fi
    echo ""
