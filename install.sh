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
    
    # Set non-interactive mode
    export DEBIAN_FRONTEND=noninteractive
    
    apt update
    apt install -y mysql-server
    
    print_success "MySQL installed successfully"
    
    # Start MySQL service
    systemctl start mysql
    systemctl enable mysql
    
    print_success "MySQL service started and enabled"
}

secure_mysql() {
    print_status "Securing MySQL installation"
    
    # Wait for MySQL to be ready
    sleep 5
    
    # Try to connect and secure MySQL
    if mysql -u root -e "SELECT 1;" &>/dev/null; then
        print_success "MySQL root access confirmed"
        
        # Remove anonymous users
        mysql -u root -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
        
        # Remove remote root access
        mysql -u root -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
        
        # Remove test database
        mysql -u root -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
        mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
        
        # Flush privileges
        mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        
        print_success "MySQL secured successfully"
    else
        print_warning "Could not connect to MySQL as root without password"
        print_warning "Attempting to use sudo mysql..."
        
        if sudo mysql -e "SELECT 1;" &>/dev/null; then
            print_success "MySQL access confirmed with sudo"
            
            # Remove anonymous users
            sudo mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
            
            # Remove remote root access
            sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
            
            # Remove test database
            sudo mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
            sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
            
            # Flush privileges
            sudo mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            
            print_success "MySQL secured successfully with sudo"
        else
            print_error "Unable to connect to MySQL. Please check the installation."
            exit 1
        fi
    fi
}

create_database_host() {
    print_status "Creating Database Host..."
    
    echo -n "Type your Password that you want the Database Host to have: "
    read -s DB_PASSWORD < /dev/tty
    echo ""
    
    if [[ -z "$DB_PASSWORD" ]]; then
        print_error "Database password cannot be empty"
        exit 1
    fi
    
    # Try with root first, then with sudo
    if mysql -u root -e "SELECT 1;" &>/dev/null; then
        mysql -u root -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';"
        mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'127.0.0.1' WITH GRANT OPTION;"
        mysql -u root -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
        mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'localhost' WITH GRANT OPTION;"
        mysql -u root -e "FLUSH PRIVILEGES;"
    else
        sudo mysql -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';"
        sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'127.0.0.1' WITH GRANT OPTION;"
        sudo mysql -e "CREATE USER IF NOT EXISTS 'pelicanuser'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
        sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'pelicanuser'@'localhost' WITH GRANT OPTION;"
        sudo mysql -e "FLUSH PRIVILEGES;"
    fi
    
    print_success "Database user 'pelicanuser' created successfully"
}

allow_external_access() {
    print_status "Allowing external database access..."
    
    # Find the MySQL configuration file
    MYCNF_FILE=""
    
    # Check common locations
    for file in "/etc/mysql/mysql.conf.d/mysqld.cnf" "/etc/mysql/my.cnf" "/etc/my.cnf"; do
        if [[ -f "$file" ]]; then
            MYCNF_FILE="$file"
            break
        fi
    done
    
    # If no config file found, create one
    if [[ -z "$MYCNF_FILE" ]]; then
        mkdir -p /etc/mysql/conf.d
        MYCNF_FILE="/etc/mysql/conf.d/pelican.cnf"
        echo -e "[mysqld]\nbind-address = 0.0.0.0" > "$MYCNF_FILE"
        print_success "Created new configuration file: $MYCNF_FILE"
    else
        # Update existing config file
        if grep -q "bind-address" "$MYCNF_FILE"; then
            sed -i 's/bind-address.*/bind-address = 0.0.0.0/' "$MYCNF_FILE"
            print_success "Updated existing bind-address setting in $MYCNF_FILE"
        else
            if grep -q "\[mysqld\]" "$MYCNF_FILE"; then
                sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' "$MYCNF_FILE"
                print_success "Added bind-address to [mysqld] section in $MYCNF_FILE"
            else
                echo -e "\n[mysqld]\nbind-address = 0.0.0.0" >> "$MYCNF_FILE"
                print_success "Added [mysqld] section with bind-address to $MYCNF_FILE"
            fi
        fi
    fi
    
    # Restart MySQL service
    systemctl restart mysql
    
    # Check if restart was successful
    if systemctl is-active --quiet mysql; then
        print_success "MySQL restarted successfully"
    else
        print_error "MySQL restart failed"
        print_warning "Please check MySQL logs: journalctl -u mysql"
        exit 1
    fi
}

setup_firewall() {
    print_status "Setting Up Firewall Rules..."
    
    if command -v ufw &> /dev/null; then
        ufw allow 3306
        print_success "UFW rule added for MySQL port 3306"
    else
        print_warning "UFW not installed, skipping firewall configuration"
        print_warning "Make sure port 3306 is accessible if using other firewall tools"
    fi
}

display_completion() {
    print_status "Successfully Created Database Host!"
    echo ""
    print_success "Pelican Database Host installation completed successfully!"
    echo ""
    print_warning "Database Details:"
    echo "Username: pelicanuser"
    echo "Host: 127.0.0.1 (or localhost)"
    echo "Port: 3306"
    echo ""
    print_warning "Go to your Admin Panel in Pelican and click on Create Database Host"
    print_warning "and enter your Password you set and follow the Instructions by Pelican."
    echo ""
    print_warning "Note: The user 'pelicanuser' has been created for both 127.0.0.1 and localhost hosts"
}

main() {
    echo -e "${BLUE}--------PELICAN DATABASE HOST INSTALLATION SCRIPT--------${NC}"
    echo -e "${GREEN}Made by: Verdanox${NC}"
    echo ""
    
    check_root
    detect_os
    
    print_warning "Installing Pelican Database Host on your server..."
    print_warning "Operating System: $OS $VERSION"
    echo ""
    
    install_mysql
    secure_mysql
    create_database_host
    allow_external_access
    setup_firewall
    display_completion
}

main "$@"
